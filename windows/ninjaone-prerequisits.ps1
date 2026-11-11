<#
.SYNOPSIS
    Instal·la els prerequisits de l'Arrencada (Git, GitHub CLI, Node LTS) a tot l'equip. Per a IT / NinjaOne.

.DESCRIPTION
    Pensat per executar-se des de NinjaOne com a SYSTEM. Instal·la amb winget, en àmbit de
    màquina (--scope machine), aquests paquets per defecte:
      - Git.Git
      - GitHub.cli
      - OpenJS.NodeJS.LTS   (cal Node >= 24; comproveu que la versió LTS actual ho compleix)

    És idempotent: si un paquet ja està instal·lat, no el toca. Excepció: Node.js. Si la
    versió instal·lada és anterior a la 24, l'actualitza (winget upgrade, àmbit màquina) i
    acaba amb error si després continua sent < 24. Es pot tornar a executar sense problema.

    IT pot preferir instal·lar aquests mateixos paquets des del catàleg de programari de
    NinjaOne; en aquest cas aquest script no és necessari.

    Registre: sortida estàndard (amb data i hora) i el fitxer
    C:\ProgramData\Fedefarma\kit-arrencada\ninjaone-prerequisits.log
    La carpeta es crea amb ACL protegida: SYSTEM i Administradors control total, Usuaris
    només lectura (es reaplica a cada execució).

    Codis de sortida: 0 tot correcte; 1 hi ha hagut algun error (o no hi ha winget).

.PARAMETER Paquets
    Identificadors winget a instal·lar. Per defecte: Git.Git, GitHub.cli, OpenJS.NodeJS.LTS.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ninjaone-prerequisits.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Paquets = @('Git.Git', 'GitHub.cli', 'OpenJS.NodeJS.LTS')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DirLog = 'C:\ProgramData\Fedefarma\kit-arrencada'
$FitxerLog = Join-Path $DirLog 'ninjaone-prerequisits.log'

function Write-Log {
    param([string]$Text)
    $linia = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Output $linia
    try {
        Add-Content -LiteralPath $FitxerLog -Value $linia -Encoding UTF8
    } catch {
        Write-Output ('{0} [avís] no puc escriure al log: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message)
    }
}

function Get-Winget {
    $base = 'C:\Program Files\WindowsApps'
    $carpetes = @(Get-ChildItem -Path (Join-Path $base 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe') -Directory -ErrorAction SilentlyContinue)
    $candidats = New-Object System.Collections.Generic.List[object]
    foreach ($c in $carpetes) {
        if ($c.Name -match '^Microsoft\.DesktopAppInstaller_(\d+(?:\.\d+)+)_x64__') {
            $exe = Join-Path $c.FullName 'winget.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $candidats.Add([pscustomobject]@{ Versio = [version]$Matches[1]; Exe = $exe })
            }
        }
    }
    if ($candidats.Count -eq 0) { return $null }
    $millor = @($candidats.ToArray() | Sort-Object -Property Versio -Descending)[0]
    return $millor.Exe
}

# Executa winget amb $ErrorActionPreference = 'Continue' i retorna el codi de sortida i el text.
function Invoke-Winget {
    param([string]$Exe, [string[]]$Arguments)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $sortida = & $Exe @Arguments 2>&1 | Out-String
        $codi = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    return [pscustomobject]@{ Codi = $codi; Sortida = $sortida }
}

# Carpeta del log amb ACL explícita i protegida (sense herència): SYSTEM i Administradors
# control total, Usuaris només lectura. Si ja existeix, es reaplica.
function Set-AclLog {
    param([string]$Cami)
    $herencia = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagacio = [System.Security.AccessControl.PropagationFlags]::None
    $permet = [System.Security.AccessControl.AccessControlType]::Allow
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $regles = @(
        @('S-1-5-18', [System.Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-544', [System.Security.AccessControl.FileSystemRights]::FullControl),
        @('S-1-5-32-545', [System.Security.AccessControl.FileSystemRights]::Read)
    )
    foreach ($r in $regles) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($r[0])
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $r[1], $herencia, $propagacio, $permet)))
    }
    Set-Acl -LiteralPath $Cami -AclObject $acl
    # El log ja existent hereta l'ACL de la carpeta.
    if (Test-Path -LiteralPath $FitxerLog -PathType Leaf) {
        $aclFitxer = Get-Acl -LiteralPath $FitxerLog
        $aclFitxer.SetAccessRuleProtection($false, $false)
        Set-Acl -LiteralPath $FitxerLog -AclObject $aclFitxer
    }
}

# Versió major de Node a partir del PATH de la màquina (després de refrescar-lo). $null si no es pot saber.
function Get-NodeMajor {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $ordre = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if ($null -eq $ordre) { return $null }
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $ordre.Source --version 2>$null | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $anterior
    }
    if ($text -match '^v(\d+)\.') { return [int]$Matches[1] }
    return $null
}

try {
    New-Item -ItemType Directory -Path $DirLog -Force | Out-Null
    Set-AclLog -Cami $DirLog
} catch {
    Write-Output ('[avís] no puc crear {0}: {1}' -f $DirLog, $_.Exception.Message)
}

Write-Log '== Inici ninjaone-prerequisits =='

$winget = Get-Winget
if ($null -eq $winget) {
    Write-Log 'ERROR: no trobo winget.exe a C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe. Cal instal·lar/actualitzar "App Installer" (winget) en aquest equip.'
    exit 1
}
Write-Log "winget: $winget"

# Codis winget que es consideren correctes tot i no ser 0:
# 0x8A15002B (cap actualització aplicable), 0x8A150061 (ja instal·lat), 3010 (cal reiniciar).
$codisOk = @(0, -1978335189, -1978335135, 3010)

$errors = New-Object System.Collections.Generic.List[string]

foreach ($id in $Paquets) {
    Write-Log "-- $id"
    try {
        $esNode = ($id -like 'OpenJS.NodeJS*')
        $llista = Invoke-Winget -Exe $winget -Arguments @('list', '--id', $id, '-e', '--accept-source-agreements')
        $accio = 'install'
        if ($llista.Codi -eq 0) {
            if (-not $esNode) {
                Write-Log "$id ja està instal·lat; no cal fer res."
                continue
            }
            $major = Get-NodeMajor
            if (($null -ne $major) -and ($major -ge 24)) {
                Write-Log "$id ja està instal·lat (node $major >= 24); no cal fer res."
                continue
            }
            $versioTxt = if ($null -eq $major) { 'desconeguda' } else { "$major" }
            Write-Log "$id instal·lat però amb Node major $versioTxt (< 24); actualitzant (àmbit màquina)..."
            $accio = 'upgrade'
        } else {
            Write-Log "$id no està instal·lat; instal·lant (àmbit màquina)..."
        }
        $inst = Invoke-Winget -Exe $winget -Arguments @(
            $accio, '--id', $id, '-e', '--scope', 'machine', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($codisOk -contains $inst.Codi) {
            Write-Log "$id : $accio correcte (codi $($inst.Codi))."
            if ($esNode) {
                $major = Get-NodeMajor
                if (($null -eq $major) -or ($major -lt 24)) {
                    $versioTxt = if ($null -eq $major) { 'desconeguda' } else { "$major" }
                    Write-Log "ERROR: després de $accio, Node continua sent < 24 (major $versioTxt)."
                    $errors.Add($id)
                } else {
                    Write-Log "Node major $major (>= 24)."
                }
            }
        } else {
            Write-Log "ERROR: $accio de $id ha fallat (codi $($inst.Codi))."
            Write-Log $inst.Sortida.Trim()
            $errors.Add($id)
        }
    } catch {
        Write-Log "ERROR: $id : $($_.Exception.Message)"
        $errors.Add($id)
    }
}

if ($errors.Count -gt 0) {
    Write-Log ('== Fi amb errors: ' + ($errors.ToArray() -join ', ') + ' ==')
    exit 1
}
Write-Log '== Fi correcte =='
exit 0
