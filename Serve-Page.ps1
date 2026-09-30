# Local, in-memory HTTP server. Bind only to loopback; no URL ACL/admin required.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$sessionPath = '/' + [guid]::NewGuid().ToString('N')
$url = "http://127.0.0.1:$port$sessionPath/"
Write-Host "Открыть: $url" -ForegroundColor Green
Write-Host 'Результаты находятся только в памяти. Завершите проверку кнопкой на странице или закройте это окно.'
try {
    if (!$NoOpen) { Start-Process $url }
    $running = $true
    while ($running) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 3000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $line = $reader.ReadLine()
            $headerBytes = 0
            do { $header = $reader.ReadLine(); $headerBytes += $header.Length; if ($headerBytes -gt 16384) { throw 'Request too large' } } while ($header)
            $request = $line -split ' '
            $status = '404 Not Found'; $body = 'Not found'; $type = 'text/plain; charset=utf-8'
            if ($request[0] -eq 'GET' -and $request[1] -eq "$sessionPath/") {
                $status = '200 OK'; $body = $page; $type = 'text/html; charset=utf-8'
            } elseif ($request[0] -eq 'POST' -and $request[1] -eq "$sessionPath/scan") {
                try {
                    $json = Invoke-LaptopScan
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
                    $status = '200 OK'; $body = $json; $type = 'application/json; charset=utf-8'
                } catch { $status = '500 Internal Server Error'; $body = '{"error":"Не удалось завершить проверку. Перезапустите программу."}'; $type = 'application/json; charset=utf-8' }
            } elseif ($request[0] -eq 'GET' -and $request[1] -eq "$sessionPath/export" -and $json) {
                $status = '200 OK'; $body = $template.Replace('__DATA_BASE64__', $payload); $type = 'text/html; charset=utf-8'
            } elseif ($request[0] -eq 'POST' -and $request[1] -eq "$sessionPath/stop") {
                $status = '200 OK'; $body = 'Stopped'; $running = $false
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $attachment = ''
            if ($request[1] -eq "$sessionPath/export" -and $json) { $attachment = 'Content-Disposition: attachment; filename="laptop-check.html"' + "`r`n" }
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`n${attachment}Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n`r`n")
            $stream.Write($head,0,$head.Length)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush()
        } catch { Write-Verbose $_.Exception.Message }
        finally { $client.Close() }
    }
} finally { $listener.Stop(); $page = $null; $json = $null; $payload = $null; $report = $null; $script:sections = $null; $script:findings = $null }
