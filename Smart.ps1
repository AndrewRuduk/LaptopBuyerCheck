function Invoke-LaptopSmartCtl {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 20)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '["\r\n]' -or $argument.EndsWith('\')) { throw 'Invalid smartctl argument.' }
        '"' + $argument + '"'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); $process.WaitForExit(); throw 'SMART: устройство не ответило за 20 секунд.' }
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($text)) { throw "smartctl не вернул JSON. $errorText" }
        # smartctl exit status is a bit mask, not a simple success/failure code.
        # Bits for failing health / old errors still contain valuable SMART data.
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } finally { $process.Dispose() }
}

function ConvertFrom-LaptopSmartData {
    param([Parameter(Mandatory=$true)]$Data, [string]$Device, [string]$DeviceType)
    $nvme = $Data.nvme_smart_health_information_log
    $attributes = @($Data.ata_smart_attributes.table | Where-Object { $null -ne $_ })
    $used = $null; $wearSource = $null
    if ($null -ne $nvme.percentage_used) { $used = [double]$nvme.percentage_used; $wearSource = 'NVMe Percentage Used' }
    elseif ($null -ne $Data.endurance_used.current_percent) { $used = [double]$Data.endurance_used.current_percent; $wearSource = 'smartctl Endurance Used' }
    $hours = $Data.power_on_time.hours
    if ($null -eq $hours) { $hours = $nvme.power_on_hours }
    if ($null -eq $hours) {
        $hourAttribute = $attributes | Where-Object { $_.id -eq 9 -and $_.name -match '^Power_On_Hours' } | Select-Object -First 1
        if ($hourAttribute) { $hours = $hourAttribute.raw.value }
    }
    $temperature = $Data.temperature.current
    if ($null -eq $temperature) { $temperature = $nvme.temperature }
    $passed = $null
    if ($null -ne $Data.smart_status.passed) { $passed = [bool]$Data.smart_status.passed }
    $mediaErrors = $nvme.media_errors
    $pending = $null; $reallocated = $null; $uncorrectable = $null
    foreach ($attribute in $attributes) {
        if ($attribute.id -eq 5 -and $attribute.name -match '^Reallocated_Sector') { $reallocated = $attribute.raw.value }
        if ($attribute.id -eq 197 -and $attribute.name -match '^Current_Pending_Sector') { $pending = $attribute.raw.value }
        if ($attribute.id -eq 198 -and $attribute.name -match '^Offline_Uncorrectable') { $uncorrectable = $attribute.raw.value }
    }
    $bytesRead = $null; $bytesWritten = $null
    if ($null -ne $nvme.data_units_read) { $bytesRead = [decimal]$nvme.data_units_read * 512000 }
    if ($null -ne $nvme.data_units_written) { $bytesWritten = [decimal]$nvme.data_units_written * 512000 }
    $messages = @($Data.smartctl.messages | Where-Object { $_.severity -in @('error','warning') } | ForEach-Object { $_.string })
    $queryError = $null
    if (($Data.smartctl.exit_status -band 3) -ne 0 -or ($null -eq $passed -and !$nvme -and !$attributes.Count)) {
        $queryError = $(if ($messages.Count) { $messages -join '; ' } else { 'SMART недоступен для этого устройства.' })
    }
    [pscustomobject]@{
        Device = $Device; DeviceType = $DeviceType; Model = $Data.model_name
        SerialNumber = $Data.serial_number; Capacity = $Data.user_capacity.bytes
        Protocol = $Data.device.protocol; Source = 'smartctl 7.5'
        HealthPassed = $passed; CriticalWarning = $nvme.critical_warning
        PercentageUsed = $used
        RemainingLifePercent = $(if ($null -ne $used -and $used -ge 0) { [math]::Max(0, 100 - $used) } else { $null })
        WearSource = $wearSource; Temperature = $temperature; PowerOnHours = $hours
        PowerCycles = $Data.power_cycle_count; UnsafeShutdowns = $nvme.unsafe_shutdowns
        MediaErrors = $mediaErrors; ErrorLogEntries = $nvme.num_err_log_entries
        ReallocatedSectors = $reallocated; PendingSectors = $pending; OfflineUncorrectable = $uncorrectable
        BytesRead = $bytesRead; BytesWritten = $bytesWritten
        AvailableSparePercent = $nvme.available_spare; AvailableSpareThreshold = $nvme.available_spare_threshold
        ExitStatus = $Data.smartctl.exit_status; Error = $queryError; Messages = $messages
        Raw = $Data
    }
}

function Get-LaptopSmartData {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $folder = Join-Path $ProjectRoot 'tools\smartmontools'
    if ([Environment]::Is64BitOperatingSystem) {
        $exe = Join-Path $folder 'bin\smartctl.exe'
        $expectedHash = 'B5DB94E5082C042BE44994B7A4FA8F7B5C8E713B2AB1C9A560D8F7A7995EA27D'
    } else {
        $exe = Join-Path $folder 'bin32\smartctl.exe'
        $expectedHash = '3084B7B54252CFAA9B1E50C3B4F555D84185BA12C82EBB0EBC0443102B573D12'
    }
    if (!(Test-Path -LiteralPath $exe)) { throw 'smartctl отсутствует: скопируйте всю папку проекта, включая tools.' }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Файл smartctl повреждён или заменён. Скопируйте исходную папку tools.' }
    $scan = Invoke-LaptopSmartCtl -Executable $exe -Arguments @('--scan-open','-j')
    $devices = @($scan.devices | Where-Object { $null -ne $_ })
    if (!$devices.Count) {
        $message = @($scan.smartctl.messages | ForEach-Object { $_.string }) -join '; '
        throw "SMART: накопители не обнаружены. $message"
    }
    $db = Join-Path $folder 'bin\drivedb.h'
    foreach ($device in $devices) {
        try {
            $argsList = @('-a','-j')
            if (Test-Path -LiteralPath $db) { $argsList += @('-B',$db) }
            if ($device.type) { $argsList += @('-d',[string]$device.type) }
            $argsList += [string]$device.name
            $data = Invoke-LaptopSmartCtl -Executable $exe -Arguments $argsList
            ConvertFrom-LaptopSmartData -Data $data -Device $device.name -DeviceType $device.type
        } catch {
            [pscustomobject]@{Device=$device.name;DeviceType=$device.type;Source='smartctl 7.5';Error=$_.Exception.Message}
        }
    }
}
