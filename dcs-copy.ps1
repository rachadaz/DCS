<#
.SYNOPSIS
    DCS Copy Workflow - Copie les fichiers OneDrive vers un share reseau.
.DESCRIPTION
    Copie les fichiers depuis un dossier OneDrive (compte standard)
    vers un partage reseau (compte admin) en utilisant des credentials
    stockes de maniere securisee.

    Concu pour tourner sur un poste Windows via le Planificateur de taches.
.PARAMETER ConfigPath
    Chemin vers le fichier config.ini (defaut: config.ini a cote du script)
.PARAMETER DryRun
    Mode simulation : affiche les actions sans les executer
.EXAMPLE
    .\dcs-copy.ps1
    .\dcs-copy.ps1 -DryRun
#>

param(
    [string]$ConfigPath,
    [switch]$DryRun
)

# ============================================================================
# CONFIGURATION
# ============================================================================

function Read-IniConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Error "ERREUR: Fichier de configuration introuvable: $Path"
        exit 1
    }

    $config = @{}
    $section = ""
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#") -or $line.StartsWith(";")) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $config.ContainsKey($section)) { $config[$section] = @{} }
        }
        elseif ($line -match '^([^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            if ($section) { $config[$section][$key] = $value }
        }
    }
    return $config
}

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("DEBUG","INFO","WARNING","ERROR")]
        [string]$Level = "INFO"
    )

    $levelPriority = @{ "DEBUG"=0; "INFO"=1; "WARNING"=2; "ERROR"=3 }
    $configLevel = if ($script:Config -and $script:Config.logging.log_level) {
        $script:Config.logging.log_level.ToUpper()
    } else { "INFO" }
    if ($levelPriority[$Level] -lt $levelPriority[$configLevel]) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"

    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "DEBUG"   { Write-Host $entry -ForegroundColor Gray }
        default   { Write-Host $entry }
    }

    $logFile = if ($script:Config) { $script:Config.logging.log_file } else { $null }
    if ($logFile) {
        $logDir = Split-Path $logFile -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $entry | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

# ============================================================================
# CONNEXION AU SHARE RESEAU
# ============================================================================

function Connect-NetworkShare {
    param([string]$SharePath)

    $credDir = "C:\ProgramData\dcs-workflow"
    $userFile = Join-Path $credDir "network_user.dat"
    $passFile = Join-Path $credDir "network_cred.dat"

    if (-not (Test-Path $userFile) -or -not (Test-Path $passFile)) {
        Write-Log "Credentials non trouves. Executez d'abord setup-credentials.ps1" -Level ERROR
        throw "Credentials manquants"
    }

    $networkUser = Get-Content $userFile -Raw
    $networkUser = $networkUser.Trim()
    $securePass = Get-Content $passFile | ConvertTo-SecureString

    $credential = New-Object System.Management.Automation.PSCredential($networkUser, $securePass)

    # Extraire le nom du serveur + partage (\\serveur\partage)
    if ($SharePath -match '^(\\\\[^\\]+\\[^\\]+)') {
        $shareRoot = $Matches[1]
    } else {
        Write-Log "Chemin de share invalide: $SharePath" -Level ERROR
        throw "Chemin UNC invalide"
    }

    Write-Log "Connexion au share $shareRoot avec $networkUser ..."

    # Deconnecter d'abord si une connexion existe deja
    try { net use $shareRoot /delete /y 2>$null | Out-Null } catch {}

    $plainPass = $credential.GetNetworkCredential().Password
    $result = net use $shareRoot /user:$networkUser $plainPass /persistent:no 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Echec de connexion au share: $result" -Level ERROR
        throw "Connexion au share echouee"
    }

    Write-Log "Connecte au share $shareRoot"
    return $shareRoot
}

function Disconnect-NetworkShare {
    param([string]$ShareRoot)
    try {
        net use $ShareRoot /delete /y 2>$null | Out-Null
        Write-Log "Share $ShareRoot deconnecte." -Level DEBUG
    } catch {}
}

# ============================================================================
# COPIE DES FICHIERS
# ============================================================================

function Copy-FilesToShare {
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [string[]]$Extensions,
        [bool]$Incremental,
        [bool]$DeleteAfterCopy,
        [switch]$DryRun
    )

    # Verifier que la source existe
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Le dossier source n'existe pas: $SourcePath" -Level ERROR
        Write-Log "Verifiez que OneDrive est synchronise et que le chemin est correct." -Level ERROR
        return @{ Copied = 0; Skipped = 0; Errors = 0 }
    }

    # Lister les fichiers source
    $sourceFiles = Get-ChildItem -Path $SourcePath -Recurse -File -ErrorAction SilentlyContinue

    # Filtrer par extension si specifie
    if ($Extensions -and $Extensions.Count -gt 0) {
        $sourceFiles = $sourceFiles | Where-Object {
            $Extensions -contains $_.Extension.ToLower()
        }
    }

    if (-not $sourceFiles -or $sourceFiles.Count -eq 0) {
        Write-Log "Aucun fichier trouve dans $SourcePath"
        return @{ Copied = 0; Skipped = 0; Errors = 0 }
    }

    Write-Log "$($sourceFiles.Count) fichier(s) trouve(s) dans la source."

    $copied = 0
    $skipped = 0
    $errors = 0

    foreach ($file in $sourceFiles) {
        # Calculer le chemin relatif pour conserver l'arborescence
        $relativePath = $file.FullName.Substring($SourcePath.Length).TrimStart('\')
        $destFile = Join-Path $DestPath $relativePath
        $destDir = Split-Path $destFile -Parent

        # Mode incremental : ne copier que si plus recent
        if ($Incremental -and (Test-Path $destFile)) {
            $destInfo = Get-Item $destFile
            if ($file.LastWriteTime -le $destInfo.LastWriteTime) {
                Write-Log "  [SKIP] $relativePath (deja a jour)" -Level DEBUG
                $skipped++
                continue
            }
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN] Copierait: $relativePath ($([math]::Round($file.Length / 1KB, 1)) Ko)"
            $copied++
            continue
        }

        try {
            # Creer le dossier de destination si necessaire
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            Copy-Item -Path $file.FullName -Destination $destFile -Force
            Write-Log "  [OK] $relativePath ($([math]::Round($file.Length / 1KB, 1)) Ko)"
            $copied++

            # Supprimer le fichier source si demande
            if ($DeleteAfterCopy) {
                Remove-Item -Path $file.FullName -Force
                Write-Log "  [DEL] Source supprimee: $relativePath" -Level DEBUG
            }
        } catch {
            Write-Log "  [ERREUR] $relativePath : $_" -Level ERROR
            $errors++
        }
    }

    return @{ Copied = $copied; Skipped = $skipped; Errors = $errors }
}

# ============================================================================
# WORKFLOW PRINCIPAL
# ============================================================================

function Invoke-Workflow {
    param(
        [hashtable]$Config,
        [switch]$DryRun
    )

    Write-Log ("=" * 60)
    Write-Log "Demarrage du workflow DCS Copy"
    Write-Log ("=" * 60)

    if ($DryRun) {
        Write-Log "*** MODE DRY-RUN : aucune modification ne sera effectuee ***"
    }

    $sourcePath     = $Config.source.path
    $destPath       = $Config.destination.path
    $extensions     = if ($Config.options.extensions) {
        ($Config.options.extensions -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    } else { @() }
    $deleteAfter    = ($Config.options.delete_after_copy -eq "true")
    $incremental    = ($Config.options.incremental -ne "false")

    Write-Log "Source      : $sourcePath"
    Write-Log "Destination : $destPath"
    Write-Log "Incremental : $incremental"
    if ($extensions.Count -gt 0) {
        Write-Log "Extensions  : $($extensions -join ', ')"
    } else {
        Write-Log "Extensions  : toutes"
    }

    # --- Connexion au share reseau ---
    $shareRoot = $null
    try {
        if (-not $DryRun) {
            $shareRoot = Connect-NetworkShare -SharePath $destPath
        } else {
            Write-Log "[DRY-RUN] Connexion au share ignoree."
        }

        # --- Copie des fichiers ---
        $stats = Copy-FilesToShare -SourcePath $sourcePath -DestPath $destPath `
                                   -Extensions $extensions -Incremental $incremental `
                                   -DeleteAfterCopy $deleteAfter -DryRun:$DryRun

        # --- Resume ---
        Write-Log ("-" * 60)
        Write-Log "Termine : $($stats.Copied) copie(s), $($stats.Skipped) ignore(s), $($stats.Errors) erreur(s)"

        if ($stats.Errors -gt 0) { return 1 }
        return 0

    } catch {
        Write-Log "Erreur: $_" -Level ERROR
        Write-Log $_.ScriptStackTrace -Level DEBUG
        return 1
    } finally {
        if ($shareRoot) {
            Disconnect-NetworkShare -ShareRoot $shareRoot
        }
    }
}

# ============================================================================
# POINT D'ENTREE
# ============================================================================

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "config.ini"
}

$script:Config = Read-IniConfig $ConfigPath

$exitCode = Invoke-Workflow -Config $script:Config -DryRun:$DryRun

exit $exitCode
