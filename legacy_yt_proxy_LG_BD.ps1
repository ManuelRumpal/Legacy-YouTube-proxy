<#
YouTube Legacy Proxy (Streaming + Robust Features, 2011 constraints)

Purpose:
- Intercept BD player legacy v2 HTTP calls on port 80.
- Map/resolve endpoints via external config (from logger).
- Enforce 2011-era constraints: H.264 High@L4.1, yuv420p, ≤1080p, AAC LC; no HDR/VP9/AV1/HEVC.
- Prefer passthrough for compliant MP4; otherwise transcode.
- On-the-fly transcoding (yt-dlp → ffmpeg pipeline) to avoid request timeout.
- While streaming, also cache output to NTFS mount for reuse and proper byte-range serving.
- Provide byte-range (206) responses from cached files.
- Log per-request status: Passthrough vs Transcoded.
#>

# -------------------------------
# Configuration
# -------------------------------
$ConfigPath     = "C:\ProxyCache\endpoints.map.json"
$MountPath      = "C:\Cache\ytcache"       # Staging/cache directory (NTFS mount point)
$PublicPath     = "C:\Cache\public"        # Published files for byte-range serving
$LogPath        = "C:\ProxyCache\session.log"
$YtdlpExe       = "yt-dlp.exe"
$FfmpegExe      = "ffmpeg.exe"
$ListenPrefix   = "http://+:80/"

# Ensure folders exist
New-Item -ItemType Directory -Path $MountPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $PublicPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path (Split-Path $ConfigPath) -ErrorAction SilentlyContinue | Out-Null
if (-not (Test-Path $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }

# Detect server IPv4 for link building
$ServerIp     = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceOperationalStatus -eq 'Up'} | Select-Object -ExpandProperty IPAddress -First 1)
$ProxyBaseUrl = "http://$ServerIp"

# -------------------------------
# Firewall rules (check-before-create)
# -------------------------------
function Ensure-FirewallRule {
    param([string]$DisplayName,[hashtable]$Params)
    $exists = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if (-not $exists) {
        New-NetFirewallRule -DisplayName $DisplayName @Params | Out-Null
    }
}

$bdPlayerIP = Read-Host "Enter BD player LAN IP (e.g., 192.168.1.100)"
Ensure-FirewallRule "Allow BD Player HTTP to Proxy" @{ Direction="Inbound"; Protocol="TCP"; LocalPort=80; RemoteAddress=$bdPlayerIP; Action="Allow" }
Ensure-FirewallRule "Allow Proxy HTTPS to YouTube" @{ Direction="Outbound"; Protocol="TCP"; RemotePort=443; Action="Allow" }
Ensure-FirewallRule "Allow Proxy DNS Forwarders" @{ Direction="Outbound"; Protocol="UDP"; RemotePort=53; Action="Allow" }

# -------------------------------
# Load external endpoint mapping
# -------------------------------
if (-not (Test-Path $ConfigPath)) {
    $bootstrap = @{
        mappings = @(
            @{ legacy = "feeds/api/standardfeeds/most_popular"; type = "feed"; modern = "yt:trending" },
            @{ legacy = "feeds/api/videos"; type = "video"; modern = "https://www.youtube.com/watch?v={v}" }
        )
        maxFeedItems = 8
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $ConfigPath -Value $bootstrap -Encoding UTF8
}
$EndpointConfig = Get-Content -Path $ConfigPath -Encoding UTF8 | ConvertFrom-Json

# -------------------------------
# Utilities
# -------------------------------
function Log-Event {
    param([string]$Message)
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogPath -Value ("[$stamp] " + $Message)
}

function Run-Proc {
    param([string]$File,[string]$Args,[switch]$Json)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Args
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "Command failed ($File): $err" }
    if ($Json) { return $out | ConvertFrom-Json } else { return $out }
}

function Is-Hdr {
    param($FormatOrMeta)
    return ($FormatOrMeta.dynamic_range -and ($FormatOrMeta.dynamic_range -match "hdr|hlg|dolby"))
}

function Needs-Transcode {
    param($Format)
    $videoOk     = ($Format.vcodec -match "^h264") -and ($Format.height -le 1080) -and (-not (Is-Hdr $Format))
    $audioOk     = ($Format.acodec -match "^aac" -or $Format.acodec -match "^mp4a")
    $containerOk = $Format.ext -eq "mp4"
    return -not ($videoOk -and $audioOk -and $containerOk)
}

function Supports-Nvenc {
    try {
        $probe = Run-Proc -File $FfmpegExe -Args "-hide_banner -encoders"
        return ($probe -match "h264_nvenc")
    } catch { return $false }
}
$UseNvenc = Supports-Nvenc
Log-Event ("Encoder: " + ($UseNvenc ? "NVENC (h264_nvenc)" : "CPU (libx264)"))

# Strict 2011 selection for direct MP4 when possible
$FormatSelectorStrict = "best[ext=mp4][vcodec^=h264][height<=1080]/bestvideo[ext=mp4][vcodec^=h264][height<=1080]+bestaudio[ext=m4a]"

# -------------------------------
# Metadata and XML
# -------------------------------
function Prepare-VideoMetadata {
    param([string]$VideoId)
    $url  = "https://www.youtube.com/watch?v=$VideoId"
    $meta = Run-Proc -File $YtdlpExe -Args "-j `"$url`"" -Json
    return @{
        Id    = $meta.id
        Title = $meta.title
        Thumb = ($meta.thumbnails | Sort-Object width -Descending | Select-Object -First 1).url
        Url   = "$ProxyBaseUrl/videoplayback?id=$($meta.id)"
    }
}

function Emit-VideoEntryXml {
    param([string]$Id,[string]$Title,[string]$Url,[string]$ThumbUrl)
@"
<entry xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <id>$Id</id>
  <title>$Title</title>
  <media:thumbnail url="$ThumbUrl" />
  <media:content url="$Url" type="video/mp4" />
</entry>
"@
}

function Resolve-VideoMetadata {
    param([string]$VideoId)
    $info  = Prepare-VideoMetadata -VideoId $VideoId
    $entry = Emit-VideoEntryXml -Id $info.Id -Title $info.Title -Url $info.Url -ThumbUrl $info.Thumb
@"
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Video</title>
$entry
</feed>
"@
}

function Resolve-StandardFeed {
    param([int]$MaxItems = 8)
    $search = "ytsearch$MaxItems:site:youtube popular"
    $results = Run-Proc -File $YtdlpExe -Args "-j `"$search`"" -Json
    $list = ($results -is [System.Array]) ? $results : @($results)
    $entriesXml = foreach ($item in $list | Select-Object -First $MaxItems) {
        $info = Prepare-VideoMetadata -VideoId $item.id
        Emit-VideoEntryXml -Id $info.Id -Title $info.Title -Url $info.Url -ThumbUrl $info.Thumb
    }
@"
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Most Popular</title>
$($entriesXml -join "`n")
</feed>
"@
}

# -------------------------------
# Byte-range file serving
# -------------------------------
function Serve-FileWithRanges {
    param($context, [string]$FilePath)

    $response = $context.Response
    $request  = $context.Request

    if (-not (Test-Path $FilePath)) {
        $response.StatusCode = 404
        $buf = [Text.Encoding]::UTF8.GetBytes("Not found")
        $response.OutputStream.Write($buf,0,$buf.Length)
        $response.OutputStream.Close()
        return
    }

    $fi = Get-Item $FilePath
    $totalLength = $fi.Length

    $response.Headers["Content-Type"]   = "video/mp4"
    $response.Headers["Accept-Ranges"]  = "bytes"
    $response.Headers["Cache-Control"]  = "private, max-age=86400"
    $response.Headers["Expires"]        = (Get-Date).AddDays(1).ToUniversalTime().ToString("R")

    $rangeHeader = $request.Headers["Range"]
    if ($rangeHeader -and $rangeHeader -match "^bytes=(\d*)-(\d*)$") {
        $start = [int64]$Matches[1]
        $end   = $Matches[2] -ne "" ? [int64]$Matches[2] : ($totalLength - 1)
        if ($start -ge $totalLength) { $start = $totalLength - 1 }
        if ($end   -ge $totalLength) { $end   = $totalLength - 1 }
        if ($end -lt $start) { $end = $start }

        $length = $end - $start + 1
        $response.StatusCode = 206
        $response.Headers["Content-Range"] = "bytes $start-$end/$totalLength"
        $response.ContentLength64 = $length

        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buffer = New-Object byte[] 65536
            $remaining = $length
            while ($remaining -gt 0) {
                $toRead = [Math]::Min($buffer.Length, $remaining)
                $read = $fs.Read($buffer, 0, $toRead)
                if ($read -le 0) { break }
                $response.OutputStream.Write($buffer, 0, $read)
                $remaining -= $read
            }
        } finally {
            $fs.Close()
            $response.OutputStream.Close()
        }
    } else {
        $response.StatusCode = 200
        $response.ContentLength64 = $totalLength
        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $buffer = New-Object byte[] 65536
            while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $response.OutputStream.Write($buffer, 0, $read)
            }
        } finally {
            $fs.Close()
            $response.OutputStream.Close()
        }
    }
}

# -------------------------------
# Streaming pipeline with concurrent cache
# -------------------------------
function Stream-And-Cache-Transcoded {
    param($context, [string]$VideoId)

    $response = $context.Response
    $response.StatusCode = 200
    $response.Headers["Content-Type"]  = "video/mp4"
    $response.Headers["Cache-Control"] = "no-cache"
    $response.SendChunked = $true

    $url = "https://www.youtube.com/watch?v=$VideoId"
    $workDir = Join-Path $MountPath $VideoId
    New-Item -ItemType Directory -Path $workDir -ErrorAction SilentlyContinue | Out-Null
    $cachePath = Join-Path $workDir "$VideoId_streaming.mp4"
    $publicOut = Join-Path $PublicPath "$VideoId.mp4"

    $ytArgs = "-f ""bestvideo[height<=1080]+bestaudio/best[height<=1080]"" -o - `"$url`""

    $videoEnc = $UseNvenc ? "h264_nvenc -preset p4" : "libx264 -preset medium"
    # Fragmented MP4 for immediate playback; ensure 2011-era constraints
    $ffArgs = @(
        "-i pipe:0",
        "-c:v $videoEnc",
        "-profile:v high",
        "-level:v 4.1",
        "-pix_fmt yuv420p",
        "-vf scale='min(1920,iw)':min(1080,ih):force_original_aspect_ratio=decrease",
        "-b:v 4M", "-maxrate 6M", "-bufsize 8M",
        "-c:a aac", "-b:a 192k", "-ar 48000", "-ac 2",
        "-movflags frag_keyframe+empty_moov",
        "-f mp4",
        "pipe:1"
    ) -join " "

    # Start yt-dlp
    $ytProc = New-Object System.Diagnostics.Process
    $ytProc.StartInfo.FileName = $YtdlpExe
    $ytProc.StartInfo.Arguments = $ytArgs
    $ytProc.StartInfo.RedirectStandardOutput = $true
    $ytProc.StartInfo.UseShellExecute = $false
    $ytProc.StartInfo.CreateNoWindow = $true

    # Start ffmpeg
    $ffProc = New-Object System.Diagnostics.Process
    $ffProc.StartInfo.FileName = $FfmpegExe
    $ffProc.StartInfo.Arguments = $ffArgs
    $ffProc.StartInfo.RedirectStandardInput  = $true
    $ffProc.StartInfo.RedirectStandardOutput = $true
    $ffProc.StartInfo.UseShellExecute = $false
    $ffProc.StartInfo.CreateNoWindow = $true

    $ytProc.Start() | Out-Null
    $ffProc.Start() | Out-Null

    # Pipe yt-dlp stdout → ffmpeg stdin
    $ytStream = $ytProc.StandardOutput.BaseStream
    $ffIn     = $ffProc.StandardInput.BaseStream
    $buffer   = New-Object byte[] 65536

    $pipeToFfmpeg = Start-Job -ScriptBlock {
        param($ytStreamParam, $ffInParam, $bufParam)
        while (($read = $ytStreamParam.Read($bufParam,0,$bufParam.Length)) -gt 0) {
            $ffInParam.Write($bufParam,0,$read)
        }
        $ffInParam.Close()
    } -ArgumentList $ytStream, $ffIn, $buffer

    # Stream ffmpeg stdout to client and cache to disk simultaneously
    $ffOut    = $ffProc.StandardOutput.BaseStream
    $cacheFs  = [System.IO.File]::Open($cachePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        while (($read = $ffOut.Read($buffer,0,$buffer.Length)) -gt 0) {
            $response.OutputStream.Write($buffer,0,$read)
            $response.OutputStream.Flush()
            $cacheFs.Write($buffer,0,$read)
            $cacheFs.Flush()
        }
    } finally {
        $cacheFs.Close()
        $response.OutputStream.Close()
    }

    # Wait for pipeline completion
    Receive-Job $pipeToFfmpeg -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $pipeToFfmpeg -Force | Out-Null
    $ytProc.WaitForExit()
    $ffProc.WaitForExit()

    # Move cached stream to public path for future byte-range requests
    if (Test-Path $cachePath) {
        Copy-Item $cachePath $publicOut -Force
    }

    Log-Event ("Transcoded: id=$VideoId, encoder=" + ($UseNvenc ? "NVENC" : "libx264") + ", cached=" + (Test-Path $publicOut))
}

# -------------------------------
# Passthrough download and serve (compliant MP4)
# -------------------------------
function Download-And-Cache-Passthrough {
    param([string]$VideoId)

    $url = "https://www.youtube.com/watch?v=$VideoId"
    $workDir = Join-Path $MountPath $VideoId
    New-Item -ItemType Directory -Path $workDir -ErrorAction SilentlyContinue | Out-Null
    $publicOut = Join-Path $PublicPath "$VideoId.mp4"

    $args = "--paths `"$workDir`" --no-part --quiet --merge-output-format mp4 -f `"$FormatSelectorStrict`" `"$url`""
    Run-Proc -File $YtdlpExe -Args $args | Out-Null

    $dlFile = Get-ChildItem -Path $workDir -Filter *.mp4 | Sort-Object Length -Descending | Select-Object -First 1
    if ($dlFile -eq $null) { throw "Passthrough download failed for $VideoId" }

    # Ensure faststart for seekability even on full file
    $faststartOut = Join-Path $workDir "$VideoId_faststart.mp4"
    $ffArgs = "-y -i `"$($dlFile.FullName)`" -c copy -movflags +faststart `"$faststartOut`""
    Run-Proc -File $FfmpegExe -Args $ffArgs | Out-Null

    Copy-Item $faststartOut $publicOut -Force
    Log-Event ("Passthrough: id=$VideoId, file=$publicOut")
}

# -------------------------------
# Streaming transcoding handler (with passthrough decision)
# -------------------------------
function Serve-VideoPlayback {
    param($context)

    $response = $context.Response
    $request  = $context.Request
    $id       = $request.QueryString["id"]

    if (-not $id) {
        $response.StatusCode = 400
        $buf = [Text.Encoding]::UTF8.GetBytes("Missing id")
        $response.OutputStream.Write($buf,0,$buf.Length)
        $response.OutputStream.Close()
        return
    }

    $publicOut = Join-Path $PublicPath "$id.mp4"

    # If we already have a cached file → serve with byte-range
    if (Test-Path $publicOut) {
        Log-Event ("Cached serve: id=$id")
        Serve-FileWithRanges -context $context -FilePath $publicOut
        return
    }

    # Decide passthrough vs. transcode using metadata formats
    try {
        $url  = "https://www.youtube.com/watch?v=$id"
        $meta = Run-Proc -File $YtdlpExe -Args "-j `"$url`"" -Json
        $candidate = $meta.formats | Where-Object { $_.ext -eq "mp4" } | Sort-Object height -Descending | Select-Object -First 1

        if ($candidate -and (-not (Needs-Transcode $candidate)) -and (-not (Is-Hdr $meta))) {
            # Passthrough: download compliant MP4 quickly, then serve with ranges
            Log-Event ("Passthrough decision: id=$id, fmt=$($candidate.vcodec)/$($candidate.acodec), h=$($candidate.height)")
            Download-And-Cache-Passthrough -VideoId $id
            Serve-FileWithRanges -context $context -FilePath $publicOut
            return
        } else {
            Log-Event ("Transcode decision: id=$id, reason=" + (
                if ($candidate -eq $null) { "no mp4 candidate" }
                elseif (Needs-Transcode $candidate) { "codec/container/height mismatch" }
                elseif (Is-Hdr $meta) { "hdr flagged" }
                else { "unknown" }
            ))
        }
    } catch {
        Log-Event ("Metadata error for id=$id: $_")
    }

    # Fallback: on-the-fly transcoding with concurrent cache, then future requests will hit cached file
    Stream-And-Cache-Transcoded -context $context -VideoId $id
}

# -------------------------------
# Listener and routing
# -------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()
Log-Event "Proxy listening on $ListenPrefix"
Write-Host "Proxy listening on $ListenPrefix"
Write-Host "Press 'q' + Enter to quit."

$reqTotal = 0
$reqByEndpoint = @{}

$quitJob = Start-Job {
    while ($true) {
        $input = Read-Host
        if ($input -eq 'q') { break }
    }
}

function Find-Mapping { param([string]$LegacyPath)
    foreach ($m in $EndpointConfig.mappings) {
        if ($LegacyPath -like "*$($m.legacy)*") { return $m }
    }
    return $null
}

while ($listener.IsListening) {
    if ($quitJob.State -eq 'Completed') { break }

    if ($listener.Pending()) {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $reqTotal++

        try {
            $path = $request.Url.AbsolutePath.TrimStart("/")
            $reqByEndpoint[$path] = ($reqByEndpoint[$path] + 1)

            if ($path -like "videoplayback*") {
                Serve-VideoPlayback -context $context
                continue
            }

            $mapping = Find-Mapping -LegacyPath $path
            $xml = $null

            if ($mapping -ne $null) {
                switch ($mapping.type) {
                    "video" {
                        $vid = $request.QueryString["v"]
                        if ($vid) {
                            Log-Event ("Resolve video: v=$vid")
                            $xml = Resolve-VideoMetadata -VideoId $vid
                        } else {
                            $xml = "<feed xmlns=""http://www.w3.org/2005/Atom""><title>Error: Missing video id</title></feed>"
                        }
                    }
                    "feed" {
                        Log-Event ("Resolve feed: path=$path")
                        if ($mapping.modern -eq "yt:trending") {
                            $xml = Resolve-StandardFeed -MaxItems $EndpointConfig.maxFeedItems
                        } else {
                            $xml = Resolve-StandardFeed -MaxItems $EndpointConfig.maxFeedItems
                        }
                    }
                    default {
                        $xml = "<feed xmlns=""http://www.w3.org/2005/Atom""><title>Stub</title></feed>"
                    }
                }
            } else {
                $xml = "<feed xmlns=""http://www.w3.org/2005/Atom""><title>Stub</title></feed>"
            }

            $buffer = [Text.Encoding]::UTF8.GetBytes($xml)
            $response.StatusCode = 200
            $response.ContentType = "application/atom+xml; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.Headers["Cache-Control"] = "no-cache"
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        }
        catch {
            Log-Event ("Handler error: $_")
            $response.StatusCode = 500
            $response.OutputStream.Close()
        }
    }
    Start-Sleep -Milliseconds 50
}

$listener.Stop()
Log-Event ("Session ended. Total requests: $reqTotal")
Log-Event ("Endpoints: " + ($reqByEndpoint.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } -join ", "))
Write-Host "Session ended. Total requests: $reqTotal"
Write-Host ("Endpoints: " + ($reqByEndpoint.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } -join ", "))