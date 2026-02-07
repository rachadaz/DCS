<#
.SYNOPSIS
    HP Email Attachment Workflow - Version PowerShell pure (aucune dependance externe).
.DESCRIPTION
    Recupere les emails envoyes par un scanner/imprimante HP via IMAP,
    extrait les pieces jointes et les enregistre sur un share reseau Windows.

    Concu pour tourner sur un poste Windows avec le Planificateur de taches.
    Aucune installation de Python ou autre prerequis necessaire.
.PARAMETER ConfigPath
    Chemin vers le fichier config.ini (defaut: config.ini a cote du script)
.PARAMETER DryRun
    Mode simulation : affiche les actions sans les executer
.EXAMPLE
    .\hp_email_attachment.ps1
    .\hp_email_attachment.ps1 -DryRun
    .\hp_email_attachment.ps1 -ConfigPath "C:\ProgramData\hp-email-attachment\config.ini"
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
    $configLevel = if ($script:Config.logging.log_level) { $script:Config.logging.log_level.ToUpper() } else { "INFO" }
    if ($levelPriority[$Level] -lt $levelPriority[$configLevel]) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"

    # Console
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "DEBUG"   { Write-Host $entry -ForegroundColor Gray }
        default   { Write-Host $entry }
    }

    # Fichier
    $logFile = $script:Config.logging.log_file
    if ($logFile) {
        $logDir = Split-Path $logFile -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $entry | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

# ============================================================================
# CLIENT IMAP (via .NET TcpClient + SslStream)
# ============================================================================

# ============================================================================
# OAUTH2 (Microsoft 365 / Azure AD)
# ============================================================================

function Get-OAuth2Token {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    Write-Log "Demande de token OAuth2 aupres d'Azure AD (tenant: $TenantId) ..."

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://outlook.office365.com/.default"
        grant_type    = "client_credentials"
    }

    try {
        $response = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
        Write-Log "Token OAuth2 obtenu avec succes."
        return $response.access_token
    } catch {
        Write-Log "Erreur lors de la demande de token OAuth2: $_" -Level ERROR
        throw "OAuth2 token request failed"
    }
}

function Build-XOAuth2String {
    param(
        [string]$Username,
        [string]$AccessToken
    )
    # Format XOAUTH2 : base64("user=" + user + "\x01auth=Bearer " + token + "\x01\x01")
    $authString = "user=$Username$([char]1)auth=Bearer $AccessToken$([char]1)$([char]1)"
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($authString))
}

# ============================================================================
# CONNEXION IMAP
# ============================================================================

function Connect-Imap {
    param(
        [string]$Server,
        [int]$Port,
        [bool]$UseSsl,
        [string]$Username,
        [string]$Password,
        [string]$AuthMethod,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    Write-Log "Connexion au serveur IMAP ${Server}:${Port} ..."

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $tcpClient.ReceiveTimeout = 30000
    $tcpClient.SendTimeout = 30000
    $tcpClient.Connect($Server, $Port)

    if ($UseSsl) {
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false)
        $sslStream.AuthenticateAsClient($Server)
        $stream = $sslStream
    } else {
        $stream = $tcpClient.GetStream()
    }

    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true

    # Lire le banner du serveur
    $banner = $reader.ReadLine()
    Write-Log "Serveur: $banner" -Level DEBUG

    $imap = @{
        TcpClient = $tcpClient
        Reader    = $reader
        Writer    = $writer
        TagId     = 1
    }

    # Authentification
    if ($AuthMethod -eq "oauth2") {
        # OAuth2 XOAUTH2
        $accessToken = Get-OAuth2Token -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        $xoauth2 = Build-XOAuth2String -Username $Username -AccessToken $accessToken
        $response = Send-ImapCommand $imap "AUTHENTICATE XOAUTH2 $xoauth2"
        if ($response -notmatch "OK") {
            Write-Log "Echec de l'authentification OAuth2 pour $Username" -Level ERROR
            Write-Log "Verifiez : tenant_id, client_id, client_secret, et les permissions Azure AD" -Level ERROR
            throw "IMAP AUTHENTICATE XOAUTH2 failed"
        }
    } else {
        # Login classique (mot de passe)
        $response = Send-ImapCommand $imap "LOGIN `"$Username`" `"$Password`""
        if ($response -notmatch "OK") {
            Write-Log "Echec de l'authentification pour $Username" -Level ERROR
            throw "IMAP LOGIN failed"
        }
    }
    Write-Log "Connexion reussie pour $Username"

    return $imap
}

function Send-ImapCommand {
    param($Imap, [string]$Command)

    $tag = "A$($Imap.TagId)"
    $Imap.TagId++

    $Imap.Writer.WriteLine("$tag $Command")

    $result = New-Object System.Text.StringBuilder
    while ($true) {
        $line = $Imap.Reader.ReadLine()
        if ($null -eq $line) { break }
        [void]$result.AppendLine($line)
        if ($line.StartsWith("$tag ")) { break }
    }

    return $result.ToString()
}

function Send-ImapCommandRaw {
    # Version qui retourne les lignes brutes (pour FETCH avec pieces binaires)
    param($Imap, [string]$Command)

    $tag = "A$($Imap.TagId)"
    $Imap.TagId++

    $Imap.Writer.WriteLine("$tag $Command")

    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = $Imap.Reader.ReadLine()
        if ($null -eq $line) { break }
        $lines.Add($line)
        if ($line.StartsWith("$tag ")) { break }
    }

    return $lines
}

function Disconnect-Imap {
    param($Imap)
    try {
        Send-ImapCommand $Imap "LOGOUT" | Out-Null
        $Imap.Reader.Close()
        $Imap.Writer.Close()
        $Imap.TcpClient.Close()
        Write-Log "Deconnexion IMAP effectuee." -Level DEBUG
    } catch {}
}

# ============================================================================
# TRAITEMENT DES EMAILS
# ============================================================================

function Search-HpEmails {
    param($Imap, [string]$Mailbox, [string[]]$HpSenders)

    $selectResult = Send-ImapCommand $Imap "SELECT `"$Mailbox`""
    Write-Log "Boite selectionnee: $Mailbox" -Level DEBUG

    $allIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($sender in $HpSenders) {
        $searchCmd = "SEARCH UNSEEN FROM `"$sender`""
        Write-Log "Recherche: $searchCmd"
        $result = Send-ImapCommand $Imap $searchCmd

        # Extraire les IDs depuis "* SEARCH 1 2 3"
        foreach ($line in $result -split "`n") {
            if ($line.Trim() -match '^\* SEARCH(.*)$') {
                $ids = $Matches[1].Trim() -split '\s+' | Where-Object { $_ -match '^\d+$' }
                foreach ($id in $ids) { [void]$allIds.Add($id) }
                Write-Log "  -> $($ids.Count) email(s) trouves pour $sender"
            }
        }
    }

    Write-Log "Total: $($allIds.Count) email(s) non lu(s) de HP"
    return @($allIds)
}

function Get-EmailRaw {
    param($Imap, [string]$MsgId)

    $lines = Send-ImapCommandRaw $Imap "FETCH $MsgId BODY[]"

    # Reconstruire le contenu brut (tout sauf la premiere ligne FETCH et la derniere ligne tag)
    $raw = New-Object System.Text.StringBuilder
    $started = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $started) {
            # La premiere ligne contient "* N FETCH (BODY[] {SIZE})"
            if ($line -match '^\* \d+ FETCH') {
                $started = $true
                continue
            }
        } else {
            # Derniere ligne = tag de reponse
            if ($line -match '^A\d+ ') { break }
            # Ligne de fermeture de FETCH ")"
            if ($i -eq ($lines.Count - 2) -and $line.Trim() -eq ")") { break }
            [void]$raw.AppendLine($line)
        }
    }

    return $raw.ToString()
}

function Parse-MimeMessage {
    param([string]$RawEmail)

    $result = @{
        Subject     = ""
        From        = ""
        Date        = ""
        Attachments = [System.Collections.Generic.List[hashtable]]::new()
    }

    # Separer headers et body
    $headerEnd = $RawEmail.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) { $headerEnd = $RawEmail.IndexOf("`n`n") }
    if ($headerEnd -lt 0) { return $result }

    $headerBlock = $RawEmail.Substring(0, $headerEnd)
    $bodyBlock = $RawEmail.Substring($headerEnd).TrimStart()

    # Parser les headers (gestion des lignes continuees)
    $headers = @{}
    $currentHeader = ""
    $currentValue = ""
    foreach ($line in $headerBlock -split "`n") {
        $line = $line.TrimEnd("`r")
        if ($line -match '^(\S+):\s*(.*)$') {
            if ($currentHeader) { $headers[$currentHeader.ToLower()] = $currentValue }
            $currentHeader = $Matches[1]
            $currentValue = $Matches[2]
        }
        elseif ($line -match '^\s+(.*)$' -and $currentHeader) {
            $currentValue += " " + $Matches[1]
        }
    }
    if ($currentHeader) { $headers[$currentHeader.ToLower()] = $currentValue }

    $result.Subject = Decode-MimeHeader ($headers["subject"])
    $result.From = Decode-MimeHeader ($headers["from"])
    $result.Date = $headers["date"]

    # Trouver le boundary pour multipart
    $contentType = $headers["content-type"]
    if (-not $contentType) { return $result }

    if ($contentType -match 'boundary="?([^";]+)"?') {
        $boundary = $Matches[1]
        Extract-Attachments -Body $bodyBlock -Boundary $boundary -Attachments $result.Attachments
    }

    return $result
}

function Decode-MimeHeader {
    param([string]$Value)
    if (-not $Value) { return "" }

    # Decode les en-tetes encodes =?charset?encoding?text?=
    $decoded = [regex]::Replace($Value, '=\?([^?]+)\?([BbQq])\?([^?]+)\?=', {
        param($m)
        $charset = $m.Groups[1].Value
        $encoding = $m.Groups[2].Value.ToUpper()
        $text = $m.Groups[3].Value

        try {
            $enc = [System.Text.Encoding]::GetEncoding($charset)
            if ($encoding -eq "B") {
                $bytes = [Convert]::FromBase64String($text)
                return $enc.GetString($bytes)
            }
            elseif ($encoding -eq "Q") {
                $text = $text -replace '_', ' '
                $text = [regex]::Replace($text, '=([0-9A-Fa-f]{2})', {
                    param($qm)
                    [char][Convert]::ToInt32($qm.Groups[1].Value, 16)
                })
                return $text
            }
        } catch {}
        return $m.Value
    })

    return $decoded
}

function Extract-Attachments {
    param(
        [string]$Body,
        [string]$Boundary,
        [System.Collections.Generic.List[hashtable]]$Attachments
    )

    $parts = $Body -split [regex]::Escape("--$Boundary")

    foreach ($part in $parts) {
        $part = $part.TrimStart("`r", "`n")
        if ($part -eq "--" -or $part.StartsWith("--")) { continue }
        if ([string]::IsNullOrWhiteSpace($part)) { continue }

        # Separer headers de la partie et contenu
        $partHeaderEnd = $part.IndexOf("`r`n`r`n")
        if ($partHeaderEnd -lt 0) { $partHeaderEnd = $part.IndexOf("`n`n") }
        if ($partHeaderEnd -lt 0) { continue }

        $partHeaders = $part.Substring(0, $partHeaderEnd)
        $partBody = $part.Substring($partHeaderEnd).TrimStart()
        # Nettoyer le trailing ) ou -- du dernier part
        $partBody = $partBody.TrimEnd("`r", "`n", ")", " ")

        # Verifier si c'est une piece jointe
        $isAttachment = $false
        $filename = ""
        $transferEncoding = ""
        $partContentType = ""

        foreach ($hLine in ($partHeaders -split "`n")) {
            $hLine = $hLine.TrimEnd("`r").Trim()
            if ($hLine -match '(?i)^Content-Disposition:\s*attachment') { $isAttachment = $true }
            if ($hLine -match '(?i)filename="?([^";]+)"?') { $filename = $Matches[1].Trim() }
            if ($hLine -match '(?i)^Content-Transfer-Encoding:\s*(\S+)') { $transferEncoding = $Matches[1].ToLower() }
            if ($hLine -match '(?i)^Content-Type:\s*(.+)$') { $partContentType = $Matches[1] }
            # Aussi chercher name= dans Content-Type
            if ($hLine -match '(?i)name="?([^";]+)"?') {
                if (-not $filename) { $filename = $Matches[1].Trim() }
            }
        }

        # Verifier les sous-parties multipart imbriquees
        if ($partContentType -match '(?i)multipart/' -and $partContentType -match 'boundary="?([^";]+)"?') {
            $subBoundary = $Matches[1]
            Extract-Attachments -Body $partBody -Boundary $subBoundary -Attachments $Attachments
            continue
        }

        if (-not $isAttachment -or -not $filename) { continue }

        $filename = Decode-MimeHeader $filename

        # Decoder le contenu
        try {
            if ($transferEncoding -eq "base64") {
                $cleanBase64 = ($partBody -replace '\s+', '')
                $bytes = [Convert]::FromBase64String($cleanBase64)
            }
            elseif ($transferEncoding -eq "quoted-printable") {
                $text = $partBody -replace '=\r?\n', ''
                $text = [regex]::Replace($text, '=([0-9A-Fa-f]{2})', {
                    param($qm)
                    [char][Convert]::ToInt32($qm.Groups[1].Value, 16)
                })
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            }
            else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($partBody)
            }
        } catch {
            Write-Log "  Erreur de decodage pour $filename : $_" -Level WARNING
            continue
        }

        $Attachments.Add(@{
            Filename = $filename
            Data     = $bytes
            Size     = $bytes.Length
        })
    }
}

# ============================================================================
# SAUVEGARDE DES PIECES JOINTES
# ============================================================================

function Get-SanitizedFilename {
    param([string]$Filename)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($c in $invalid) { $Filename = $Filename.Replace($c, '_') }
    $Filename = $Filename.Trim('. ')
    if (-not $Filename) { $Filename = "sans_nom" }
    return $Filename
}

function Save-Attachment {
    param(
        [string]$DestDir,
        [string]$Filename,
        [byte[]]$Data
    )

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $filepath = Join-Path $DestDir $Filename

    # Gestion des doublons
    if (Test-Path $filepath) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($Filename)
        $ext = [System.IO.Path]::GetExtension($Filename)
        $counter = 1
        while (Test-Path $filepath) {
            $filepath = Join-Path $DestDir "${name}_${counter}${ext}"
            $counter++
        }
    }

    [System.IO.File]::WriteAllBytes($filepath, $Data)
    Write-Log "  Piece jointe sauvegardee: $filepath"
    return $filepath
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
    Write-Log "Demarrage du workflow HP Email Attachment"
    Write-Log ("=" * 60)

    if ($DryRun) {
        Write-Log "*** MODE DRY-RUN : aucune modification ne sera effectuee ***"
    }

    # --- Lecture de la config ---
    $imapServer    = $Config.email.imap_server
    $imapPort      = [int]($Config.email.imap_port)
    $useSsl        = ($Config.email.use_ssl -eq "true")
    $username      = $Config.email.username
    $password      = $Config.email.password
    $authMethod    = if ($Config.email.auth_method) { $Config.email.auth_method.ToLower() } else { "basic" }
    $tenantId      = $Config.email.tenant_id
    $clientId      = $Config.email.client_id
    $clientSecret  = $Config.email.client_secret
    $hpSenders     = ($Config.email.hp_sender -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    $mailbox       = if ($Config.email.mailbox) { $Config.email.mailbox } else { "INBOX" }

    $sharePath      = $Config.storage.share_path
    $organizeByDate = ($Config.storage.organize_by_date -eq "true")
    $filePrefix     = $Config.storage.file_prefix

    $markAsRead   = ($Config.processing.mark_as_read -eq "true")
    $moveToFolder = $Config.processing.move_to_folder
    $deleteAfter  = ($Config.processing.delete_after_processing -eq "true")
    $allowedExts  = ($Config.processing.allowed_extensions -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }

    # --- Verifier le share ---
    if (-not $DryRun) {
        if (-not (Test-Path $sharePath)) {
            Write-Log "Le chemin du share n'existe pas: $sharePath" -Level ERROR
            Write-Log "Verifiez que le partage reseau est accessible (ex: dir $sharePath)" -Level ERROR
            return 1
        }
    }

    # --- Connexion IMAP ---
    $imap = $null
    try {
        $imap = Connect-Imap -Server $imapServer -Port $imapPort -UseSsl $useSsl `
                             -Username $username -Password $password `
                             -AuthMethod $authMethod -TenantId $tenantId `
                             -ClientId $clientId -ClientSecret $clientSecret

        # --- Recherche des mails HP ---
        $msgIds = Search-HpEmails -Imap $imap -Mailbox $mailbox -HpSenders $hpSenders

        if ($msgIds.Count -eq 0) {
            Write-Log "Aucun nouveau mail HP a traiter."
            return 0
        }

        # --- Traitement de chaque mail ---
        $totalAttachments = 0

        foreach ($msgId in $msgIds) {
            $rawEmail = Get-EmailRaw -Imap $imap -MsgId $msgId
            $parsed = Parse-MimeMessage -RawEmail $rawEmail

            Write-Log "Traitement du mail: '$($parsed.Subject)' de $($parsed.From) ($($parsed.Date))"

            if ($parsed.Attachments.Count -eq 0) {
                Write-Log "  Aucune piece jointe exploitable dans ce mail."
                continue
            }

            $savedThisMail = 0

            foreach ($att in $parsed.Attachments) {
                $filename = Get-SanitizedFilename $att.Filename
                $ext = [System.IO.Path]::GetExtension($filename).ToLower()

                # Filtrer par extension
                if ($allowedExts.Count -gt 0 -and $ext -notin $allowedExts) {
                    Write-Log "  Piece jointe ignoree (extension $ext): $filename"
                    continue
                }

                # Construire le chemin de destination
                if ($organizeByDate) {
                    $dateFolder = Get-Date -Format "yyyy\\MM\\dd"
                    $destDir = Join-Path $sharePath $dateFolder
                } else {
                    $destDir = $sharePath
                }

                if ($filePrefix) { $filename = "$filePrefix$filename" }

                if ($DryRun) {
                    Write-Log "  [DRY-RUN] Sauvegarderait: $destDir\$filename ($($att.Size) octets)"
                } else {
                    Save-Attachment -DestDir $destDir -Filename $filename -Data $att.Data
                }
                $savedThisMail++
            }

            $totalAttachments += $savedThisMail

            # Post-traitement du mail
            if ($savedThisMail -gt 0 -and -not $DryRun) {
                if ($markAsRead) {
                    Send-ImapCommand $imap "STORE $msgId +FLAGS (\Seen)" | Out-Null
                    Write-Log "  Mail marque comme lu" -Level DEBUG
                }
                if ($moveToFolder) {
                    $copyResult = Send-ImapCommand $imap "COPY $msgId `"$moveToFolder`""
                    if ($copyResult -match "OK") {
                        Send-ImapCommand $imap "STORE $msgId +FLAGS (\Deleted)" | Out-Null
                        Send-ImapCommand $imap "EXPUNGE" | Out-Null
                        Write-Log "  Mail deplace vers '$moveToFolder'" -Level DEBUG
                    } else {
                        Write-Log "  Impossible de deplacer vers '$moveToFolder' (le dossier existe-t-il?)" -Level WARNING
                    }
                }
                elseif ($deleteAfter) {
                    Send-ImapCommand $imap "STORE $msgId +FLAGS (\Deleted)" | Out-Null
                    Send-ImapCommand $imap "EXPUNGE" | Out-Null
                    Write-Log "  Mail supprime" -Level DEBUG
                }
            }
            elseif ($savedThisMail -gt 0 -and $DryRun) {
                if ($markAsRead)   { Write-Log "  [DRY-RUN] Marquerait comme lu" }
                if ($moveToFolder) { Write-Log "  [DRY-RUN] Deplacerait vers '$moveToFolder'" }
                if ($deleteAfter)  { Write-Log "  [DRY-RUN] Supprimerait le mail" }
            }
        }

        Write-Log ("-" * 60)
        Write-Log "Termine: $($msgIds.Count) email(s) traite(s), $totalAttachments piece(s) jointe(s) sauvegardee(s)"
        return 0

    } catch {
        Write-Log "Erreur: $_" -Level ERROR
        Write-Log $_.ScriptStackTrace -Level DEBUG
        return 1
    } finally {
        if ($imap) { Disconnect-Imap $imap }
    }
}

# ============================================================================
# POINT D'ENTREE
# ============================================================================

# Chemin config par defaut : config.ini a cote du script
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "config.ini"
}

$script:Config = Read-IniConfig $ConfigPath

$exitCode = Invoke-Workflow -Config $script:Config -DryRun:$DryRun

exit $exitCode
