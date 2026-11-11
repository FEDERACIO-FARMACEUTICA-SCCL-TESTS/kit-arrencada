<#
.SYNOPSIS
    Arrencada: deixa un portàtil Windows a punt per treballar al repositori del producte amb Gentle Shell.

.DESCRIPTION
    S'executa amb l'usuari habitual (sense permisos d'administrador). Fa 7 passos:
      1. Comprova que hi ha git, gh (GitHub CLI) i Node >= 24. NO els instal·la mai:
         els instal·la IT amb NinjaOne (script ninjaone-prerequisits.ps1).
      2. Instal·la Gentle Shell (instal·lador oficial, verificat amb SHA-256) si no hi és.
      3. Inicia sessió a GitHub (gh auth login --web) només si cal, i configura git amb gh.
      4. Configura user.name / user.email de git només si no estan definits globalment.
      5. Clona el repositori (si ja hi és clonat, no fa res).
      6. Instal·la les dependències (npm ci, o npm install si no hi ha package-lock.json).
      7. Obre Gentle Shell dins la carpeta del projecte.

    No demana, no mostra i no desa mai cap token.

    Codis de sortida:
      0  correcte
      64 ús o dades d'entrada incorrectes
      10 manca un prerequisit que l'usuari no pot instal·lar (cal demanar-ho a IT)
      11 error de descàrrega o de suma de verificació
      12 la instal·lació de Gentle Shell no s'ha acabat
      13 error d'inici de sessió a GitHub o d'accés al repositori
      1  qualsevol altre error

    Variable d'entorn opcional: ARRENCADA_DOMINIS (dominis de correu permets, separats per
    espais; per defecte "fedefarma.com").

.PARAMETER Repo
    Repositori en format ORG/NOM. Si no s'indica, es pregunta dins del propi PowerShell.

.PARAMETER Directori
    Carpeta on clonar. Per defecte: "$HOME\projectes\<nom>".

.PARAMETER Correu
    Correu per a git (només si user.email no està definit). Si no s'indica, es pregunta.

.PARAMETER NoObrir
    No obre Gentle Shell al final (pas 7).

.PARAMETER SenseGentleShell
    Salta la instal·lació de Gentle Shell (pas 2).

.EXAMPLE
    .\arrencada.ps1 -Repo fedefarma/el-meu-producte

.EXAMPLE
    .\arrencada.ps1 -Repo fedefarma/el-meu-producte -Correu nom.cognom@fedefarma.com -NoObrir
#>
[CmdletBinding()]
param(
    [string]$Repo,

    [string]$Directori,

    [string]$Correu,

    [switch]$NoObrir,

    [switch]$SenseGentleShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[arrencada]'
$script:CodiNatiu = 0

function Write-Pas {
    param([int]$Numero, [string]$Text)
    Write-Host ''
    Write-Host "$($script:Prefix) Pas $Numero/7: $Text"
}

function Write-Info {
    param([string]$Text)
    Write-Host "$($script:Prefix) $Text"
}

function Stop-Arrencada {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    [Console]::Error.WriteLine("$($script:Prefix) ERROR: $Message")
    exit $Code
}

# Executa una ordre nativa amb $ErrorActionPreference = 'Continue' (a Windows PowerShell 5.1
# el stderr d'una ordre nativa podria llançar una excepció) i deixa el codi de sortida a
# $script:CodiNatiu. Retorna la sortida estàndard.
function Invoke-Nativ {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Bloc,
        [switch]$IgnoraErrors
    )
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:CodiNatiu = 0
    try {
        if ($IgnoraErrors) {
            $sortida = & $Bloc 2>$null
        } else {
            $sortida = & $Bloc
        }
        $script:CodiNatiu = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    return $sortida
}

# Executa una ordre interactiva connectada a la consola (sense capturar la sortida), perquè
# programes com 'gh auth login' o 'gentle-shell' necessiten un terminal real. Passa per
# cmd.exe perquè funcioni també amb shims .cmd (npm, gentle-shell). Retorna el codi de sortida.
# Només s'hi passen arguments fixos del propi script, mai text de l'usuari.
function Invoke-Interactiu {
    param([Parameter(Mandatory = $true)][string]$Linia)
    # Set-Location does not change the process directory, so pass it explicitly.
    $carpeta = (Get-Location).ProviderPath
    $proces = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', $Linia) -WorkingDirectory $carpeta -NoNewWindow -Wait -PassThru
    return $proces.ExitCode
}

function Update-PathSessio {
    $maquina = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $usuari = [Environment]::GetEnvironmentVariable('Path', 'User')
    $actual = $env:Path
    $vistos = @{}
    $llista = New-Object System.Collections.Generic.List[string]
    foreach ($bloc in @($maquina, $usuari, $actual)) {
        if ([string]::IsNullOrEmpty($bloc)) { continue }
        foreach ($entrada in ($bloc -split ';')) {
            $e = $entrada.Trim()
            if ($e.Length -eq 0) { continue }
            $clau = $e.TrimEnd('\').ToLowerInvariant()
            if (-not $vistos.ContainsKey($clau)) {
                $vistos[$clau] = $true
                $llista.Add($e)
            }
        }
    }
    $env:Path = ($llista.ToArray()) -join ';'
}

function Test-Ordre {
    param([string]$Nom)
    return ($null -ne (Get-Command $Nom -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------- Validació d'entrada

# Cap caràcter de control (CR, LF, ...) en cap valor d'entrada.
function Test-Control {
    param([string]$Text)
    return (($null -ne $Text) -and ($Text -match '[\x00-\x1F\x7F]'))
}

# Valida forma i domini d'un correu; surt amb 64 si no és vàlid.
function Assert-Correu {
    param([string]$Valor)
    if (Test-Control $Valor) {
        Stop-Arrencada -Code 64 -Message 'El correu conté caràcters de control.'
    }
    if ($Valor -notmatch '^[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})$') {
        Stop-Arrencada -Code 64 -Message "El correu '$Valor' no és vàlid."
    }
    $domini = $Matches[1].ToLowerInvariant()
    $dominisText = $env:ARRENCADA_DOMINIS
    if ([string]::IsNullOrWhiteSpace($dominisText)) { $dominisText = 'fedefarma.com' }
    $dominis = @($dominisText.ToLowerInvariant() -split '\s+' | Where-Object { $_.Length -gt 0 })
    if ($dominis -notcontains $domini) {
        Stop-Arrencada -Code 64 -Message ("El domini '$domini' no està permès. Dominis permesos: " + ($dominis -join ', ') + '.')
    }
}

if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = Read-Host "$($script:Prefix) Repositori (ORG/NOM)"
    if ($null -eq $Repo) { $Repo = '' }
    $Repo = $Repo.Trim()
}
if (Test-Control $Repo) {
    Stop-Arrencada -Code 64 -Message 'El repositori conté caràcters de control.'
}
if (Test-Control $Directori) {
    Stop-Arrencada -Code 64 -Message 'La carpeta conté caràcters de control.'
}
if (-not [string]::IsNullOrWhiteSpace($Correu)) {
    # Correu explícit: es valida ara, abans de qualsevol efecte lateral.
    $Correu = $Correu.Trim()
    Assert-Correu $Correu
}

$partsRepo = @($Repo -split '/')
if ($partsRepo.Count -ne 2) {
    Stop-Arrencada -Code 64 -Message "El repositori ha de tenir el format ORG/NOM (rebut: '$Repo')."
}
$orgRepo = $partsRepo[0]
$nomRepo = $partsRepo[1]
if ($orgRepo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') {
    Stop-Arrencada -Code 64 -Message "L'organització '$orgRepo' no és vàlida."
}
if (($nomRepo.Length -lt 3) -or ($nomRepo.Length -gt 50) -or ($nomRepo -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$')) {
    Stop-Arrencada -Code 64 -Message "El nom del repositori '$nomRepo' no és vàlid (3-50 caràcters, minúscules, xifres i guions)."
}
$repoComplet = "$orgRepo/$nomRepo"

if ([string]::IsNullOrWhiteSpace($Directori)) {
    $Directori = Join-Path $HOME ("projectes\" + $nomRepo)
}
# Ruta absoluta resolta una sola vegada (els passos 6 i 7 canvien de carpeta).
$Directori = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directori)

try {

    # ------------------------------------------------------------ Pas 1: prerequisits
    Write-Pas 1 'Comprovant prerequisits (git, gh, node >= 24)...'
    Update-PathSessio

    $manca = New-Object System.Collections.Generic.List[string]
    foreach ($ordre in @('git', 'gh', 'node')) {
        if (-not (Test-Ordre $ordre)) { $manca.Add($ordre) }
    }
    if ($manca.Count -gt 0) {
        Stop-Arrencada -Code 10 -Message ("Falten aquests programes: " + ($manca.ToArray() -join ', ') +
            ". No els pots instal·lar tu: demana a IT (NinjaOne) que t'instal·li Git, GitHub CLI i Node LTS i torna a executar aquest script.")
    }

    $versioNode = (@(Invoke-Nativ { node --version }) -join '').Trim()
    if ($script:CodiNatiu -ne 0) {
        Stop-Arrencada -Code 10 -Message "No he pogut executar 'node --version'. Demana a IT (NinjaOne) que reinstal·li Node LTS."
    }
    if ($versioNode -notmatch '^v(\d+)\.') {
        Stop-Arrencada -Code 10 -Message "No entenc la versió de Node ('$versioNode'). Demana a IT (NinjaOne) que reinstal·li Node LTS."
    }
    $majorNode = [int]$Matches[1]
    if ($majorNode -lt 24) {
        Stop-Arrencada -Code 10 -Message "Node $versioNode és massa antic (cal >= 24). Demana a IT (NinjaOne) que l'actualitzi."
    }
    Write-Info "Prerequisits correctes (node $versioNode)."

    # ------------------------------------------------------------ Pas 2: Gentle Shell
    Write-Pas 2 'Gentle Shell...'
    if ($SenseGentleShell) {
        Write-Info 'Saltat (-SenseGentleShell).'
    } elseif (Test-Ordre 'gentle-shell') {
        Write-Info 'Gentle Shell ja està instal·lat.'
    } else {
        $baseUrl = 'https://github.com/Gentleman-Programming/gentle-shell/releases/latest/download'
        $nomZip = 'gentle-shell-installer-windows.zip'
        $nomSums = 'gentle-shell-installers-SHA256SUMS.txt'
        $temp = Join-Path $env:TEMP ('arrencada-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            $fitxerZip = Join-Path $temp $nomZip
            $fitxerSums = Join-Path $temp $nomSums

            Write-Info "Descarregant l'instal·lador oficial de Gentle Shell..."
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$nomSums" -OutFile $fitxerSums
                Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$nomZip" -OutFile $fitxerZip
            } catch {
                Stop-Arrencada -Code 11 -Message "No he pogut descarregar l'instal·lador de Gentle Shell: $($_.Exception.Message)"
            }

            $esperat = $null
            foreach ($linia in (Get-Content -LiteralPath $fitxerSums)) {
                if ($linia -match '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') {
                    if ($Matches[2] -eq $nomZip) { $esperat = $Matches[1] }
                }
            }
            if ($null -eq $esperat) {
                Remove-Item -LiteralPath $fitxerZip -Force -ErrorAction SilentlyContinue
                Stop-Arrencada -Code 11 -Message "No hi ha cap suma SHA-256 per a $nomZip a $nomSums. He esborrat la descàrrega."
            }
            $real = (Get-FileHash -Algorithm SHA256 -LiteralPath $fitxerZip).Hash
            if (-not [string]::Equals($real, $esperat, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $fitxerZip -Force -ErrorAction SilentlyContinue
                Stop-Arrencada -Code 11 -Message "La suma SHA-256 de $nomZip no coincideix. He esborrat la descàrrega."
            }
            Write-Info 'Suma SHA-256 verificada.'

            $carpetaExtreta = Join-Path $temp 'extret'
            try {
                Expand-Archive -LiteralPath $fitxerZip -DestinationPath $carpetaExtreta -Force
            } catch {
                Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
                Stop-Arrencada -Code 11 -Message "No he pogut descomprimir l'instal·lador de Gentle Shell: $($_.Exception.Message)"
            }
            $instalador = Join-Path $carpetaExtreta 'Gentle Shell Installer\Install Gentle Shell.cmd'
            if (-not (Test-Path -LiteralPath $instalador -PathType Leaf)) {
                $trobat = @(Get-ChildItem -LiteralPath $carpetaExtreta -Recurse -Filter 'Install Gentle Shell.cmd' -File -ErrorAction SilentlyContinue)
                if ($trobat.Count -eq 0) {
                    Stop-Arrencada -Code 11 -Message "El zip descarregat no conté 'Install Gentle Shell.cmd'."
                }
                $instalador = $trobat[0].FullName
            }

            Write-Info "S'obrirà l'instal·lador de Gentle Shell i després un assistent al navegador."
            Write-Info "Acaba l'assistent fins al final; aquest script espera."
            $proces = Start-Process -FilePath $instalador -WorkingDirectory (Split-Path -Parent $instalador) -Wait -PassThru
            if ($proces.ExitCode -ne 0) {
                Write-Info "L'instal·lador ha acabat amb el codi $($proces.ExitCode)."
            }
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }

        Update-PathSessio
        if (-not (Test-Ordre 'gentle-shell')) {
            Stop-Arrencada -Code 12 -Message "Gentle Shell encara no es troba. Acaba l'assistent d'instal·lació, tanca aquesta finestra i torna a executar l'script."
        }
        Write-Info 'Gentle Shell instal·lat.'
    }

    # ------------------------------------------------------------ Pas 3: GitHub
    Write-Pas 3 'Sessió de GitHub...'
    # '--active' avoids a false negative when a stale second account is also stored.
    Invoke-Nativ { gh auth status --hostname github.com --active } -IgnoraErrors | Out-Null
    if ($script:CodiNatiu -ne 0) {
        Invoke-Nativ { gh auth status } -IgnoraErrors | Out-Null
    }
    if ($script:CodiNatiu -ne 0) {
        Write-Info "Cal iniciar sessió a GitHub. S'obrirà el navegador; segueix les instruccions."
        $codiLogin = Invoke-Interactiu 'gh auth login --hostname github.com --web --git-protocol https'
        if ($codiLogin -ne 0) {
            Stop-Arrencada -Code 13 -Message "No s'ha pogut iniciar sessió a GitHub (codi $codiLogin)."
        }
    } else {
        Write-Info 'Ja tens sessió iniciada a GitHub.'
    }
    Invoke-Nativ { gh auth setup-git } | Out-Null
    if ($script:CodiNatiu -ne 0) {
        Stop-Arrencada -Code 13 -Message "No s'ha pogut configurar git amb gh (codi $($script:CodiNatiu))."
    }
    Invoke-Nativ { gh repo view $repoComplet --json name } -IgnoraErrors | Out-Null
    if ($script:CodiNatiu -ne 0) {
        Stop-Arrencada -Code 13 -Message "No tens accés al repositori $repoComplet (o no existeix). Demana accés a Plataforma i torna-ho a provar."
    }

    # ------------------------------------------------------------ Pas 4: identitat de git
    Write-Pas 4 'Identitat de git...'
    $nomGit = (@(Invoke-Nativ { git config --global user.name } -IgnoraErrors) -join '').Trim()
    $correuGit = (@(Invoke-Nativ { git config --global user.email } -IgnoraErrors) -join '').Trim()

    # El correu es valida abans d'escriure res a git (nom inclòs).
    $correuNou = $null
    if ($correuGit.Length -eq 0) {
        $correuNou = $Correu
        if ([string]::IsNullOrWhiteSpace($correuNou)) {
            $correuNou = Read-Host "$($script:Prefix) Escriu el teu correu corporatiu"
        }
        if ($null -eq $correuNou) { $correuNou = '' }
        $correuNou = $correuNou.Trim()
        Assert-Correu $correuNou
    }

    if ($nomGit.Length -eq 0) {
        $nomGh = (@(Invoke-Nativ { gh api user --jq '.name // .login' } -IgnoraErrors) -join '').Trim()
        if (($script:CodiNatiu -ne 0) -or ($nomGh.Length -eq 0)) {
            Stop-Arrencada -Code 13 -Message "No he pogut obtenir el teu nom des de GitHub."
        }
        Invoke-Nativ { git config --global user.name $nomGh } | Out-Null
        if ($script:CodiNatiu -ne 0) {
            Stop-Arrencada -Code 1 -Message "No he pogut desar user.name a git."
        }
        Write-Info "git user.name configurat: $nomGh"
    } else {
        Write-Info 'git user.name ja està definit; no el toco.'
    }

    if ($null -ne $correuNou) {
        Invoke-Nativ { git config --global user.email $correuNou } | Out-Null
        if ($script:CodiNatiu -ne 0) {
            Stop-Arrencada -Code 1 -Message "No he pogut desar user.email a git."
        }
        Write-Info "git user.email configurat: $correuNou"
    } else {
        Write-Info 'git user.email ja està definit; no el toco.'
    }

    # ------------------------------------------------------------ Pas 5: clonar
    Write-Pas 5 "Clonant $repoComplet a $Directori ..."
    $clonar = $true
    if (Test-Path -LiteralPath $Directori -PathType Leaf) {
        Stop-Arrencada -Code 64 -Message "'$Directori' és un fitxer, no una carpeta."
    }
    if (Test-Path -LiteralPath $Directori -PathType Container) {
        $contingut = @(Get-ChildItem -LiteralPath $Directori -Force -ErrorAction SilentlyContinue)
        if ($contingut.Count -gt 0) {
            $origen = ''
            if (Test-Path -LiteralPath (Join-Path $Directori '.git')) {
                $origen = (@(Invoke-Nativ { git -C $Directori remote get-url origin } -IgnoraErrors) -join '').Trim()
                if ($script:CodiNatiu -ne 0) { $origen = '' }
            }
            # Identitat exacta: host github.com + propietari/repositori (formes https, scp i ssh://).
            $origenNorm = $origen.ToLowerInvariant().TrimEnd('/')
            if ($origenNorm.EndsWith('.git')) { $origenNorm = $origenNorm.Substring(0, $origenNorm.Length - 4) }
            $rutaOrigen = ''
            foreach ($prefix in @('https://github.com/', 'git@github.com:', 'ssh://git@github.com/')) {
                if ($origenNorm.StartsWith($prefix)) { $rutaOrigen = $origenNorm.Substring($prefix.Length); break }
            }
            if (($rutaOrigen.Length -gt 0) -and ($rutaOrigen -ceq $repoComplet.ToLowerInvariant())) {
                Write-Info 'El repositori ja està clonat; no el torno a clonar.'
                $clonar = $false
            } else {
                Stop-Arrencada -Code 64 -Message "La carpeta '$Directori' no és buida i no és un clon de $repoComplet. Tria una altra carpeta amb -Directori."
            }
        }
    }
    if ($clonar) {
        $pare = Split-Path -Parent $Directori
        if (-not [string]::IsNullOrEmpty($pare) -and -not (Test-Path -LiteralPath $pare)) {
            New-Item -ItemType Directory -Path $pare -Force | Out-Null
        }
        Invoke-Nativ { gh repo clone $repoComplet $Directori } | Out-Null
        if ($script:CodiNatiu -ne 0) {
            Stop-Arrencada -Code 1 -Message "No s'ha pogut clonar $repoComplet (codi $($script:CodiNatiu))."
        }
    }

    # ------------------------------------------------------------ Pas 6: dependències
    Write-Pas 6 'Instal·lant dependències...'
    Set-Location -LiteralPath $Directori
    if (-not (Test-Path -LiteralPath (Join-Path $Directori 'package.json') -PathType Leaf)) {
        Write-Info 'No hi ha package.json; no cal instal·lar dependències.'
    } elseif (Test-Path -LiteralPath (Join-Path $Directori 'package-lock.json') -PathType Leaf) {
        $codiNpm = Invoke-Interactiu 'npm ci'
        if ($codiNpm -ne 0) {
            Stop-Arrencada -Code 1 -Message "'npm ci' ha fallat (codi $codiNpm)."
        }
    } else {
        $codiNpm = Invoke-Interactiu 'npm install'
        if ($codiNpm -ne 0) {
            Stop-Arrencada -Code 1 -Message "'npm install' ha fallat (codi $codiNpm)."
        }
    }

    # ------------------------------------------------------------ Pas 7: obrir
    Write-Pas 7 'Final.'
    Write-Info 'Tot a punt!'
    Write-Info "  Repositori: $repoComplet"
    Write-Info "  Carpeta:    $Directori"
    if ($NoObrir) {
        Write-Info "Per començar: obre una terminal a la carpeta i executa 'gentle-shell'. Dins, prova /gentle:guide."
    } elseif ($SenseGentleShell -and -not (Test-Ordre 'gentle-shell')) {
        Write-Info "Gentle Shell no està instal·lat (-SenseGentleShell); no l'obro."
    } else {
        Write-Info "Obrint Gentle Shell... Dins, prova /gentle:guide per a una guia pas a pas."
        $codiGs = Invoke-Interactiu 'gentle-shell'
        if ($codiGs -ne 0) {
            Write-Info "Gentle Shell ha acabat amb el codi $codiGs."
        }
    }
    exit 0

} catch {
    Stop-Arrencada -Code 1 -Message "Error inesperat: $($_.Exception.Message)"
}
