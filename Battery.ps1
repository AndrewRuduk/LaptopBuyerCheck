function ConvertFrom-LaptopBatteryXml {
    param([Parameter(Mandatory=$true)][string]$Path)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        $doc = [Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $doc.Load($reader)
    } finally { $reader.Dispose() }
    $nodes = @($doc.SelectNodes('//*[local-name()="Batteries"]/*[local-name()="Battery"]'))
    if (!$nodes.Count) { throw 'powercfg: аккумуляторы не обнаружены.' }
    foreach ($node in $nodes) {
        $design = $node.SelectSingleNode('*[local-name()="DesignCapacity"]')
        $full = $node.SelectSingleNode('*[local-name()="FullChargeCapacity"]')
        $cycle = $node.SelectSingleNode('*[local-name()="CycleCount"]')
        $name = $node.SelectSingleNode('*[local-name()="Id"]')
        if (!$name) { $name = $node.SelectSingleNode('*[local-name()="Name"]') }
        $d = 0L; $f = 0L; $c = 0L
        $health = $null; $cycles = $null
        if ($design) { [void][long]::TryParse($design.InnerText, [ref]$d) }
        if ($full) { [void][long]::TryParse($full.InnerText, [ref]$f) }
        if ($d -gt 0 -and $f -gt 0) { $health = [math]::Round(100.0 * $f / $d, 1) }
        if ($cycle -and [long]::TryParse($cycle.InnerText, [ref]$c) -and $c -ge 0) { $cycles = $c }
        [pscustomobject]@{
            Battery = $(if ($name) { $name.InnerText } else { 'Battery' })
            DesignCapacity = $(if ($d -gt 0) { $d } else { $null })
            FullChargeCapacity = $(if ($f -gt 0) { $f } else { $null })
            RemainingCapacityPercent = $health
            CycleCount = $cycles
            Source = 'powercfg'
        }
    }
}

function Get-LaptopBatteryCapacity {
    $wmiRows = @(); $wmiError = $null
    try {
        $design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop)
        $full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
        foreach ($d in $design) {
            $f = $full | Where-Object InstanceName -eq $d.InstanceName | Select-Object -First 1
            $health = $null
            if ($d.DesignedCapacity -gt 0 -and $f.FullChargedCapacity -gt 0) { $health = [math]::Round(100.0 * $f.FullChargedCapacity / $d.DesignedCapacity, 1) }
            $wmiRows += [pscustomobject]@{Battery=$d.InstanceName;DesignCapacity=$d.DesignedCapacity;FullChargeCapacity=$f.FullChargedCapacity;RemainingCapacityPercent=$health;CycleCount=$null;Source='WMI'}
        }
        if ($wmiRows.Count -and !@($wmiRows | Where-Object { $null -eq $_.RemainingCapacityPercent }).Count) { return $wmiRows }
        $wmiError = 'WMI не вернул полную ёмкость.'
    } catch { $wmiError = $_.Exception.Message }
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) ('LaptopBuyerCheck-battery-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $output = & "$env:SystemRoot\System32\powercfg.exe" /batteryreport /output $tempFile /xml 2>&1
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $tempFile)) { throw ('powercfg: ' + ($output -join ' ')) }
        $powerRows = @(ConvertFrom-LaptopBatteryXml -Path $tempFile)
        if (!@($powerRows | Where-Object { $null -ne $_.RemainingCapacityPercent }).Count) { throw 'powercfg не предоставил ёмкость батареи.' }
        return $powerRows
    } catch {
        if ($wmiRows.Count) { return $wmiRows }
        throw "Не удалось прочитать ёмкость. WMI: $wmiError; $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}
