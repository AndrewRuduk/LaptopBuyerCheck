#requires -Version 5.1
[CmdletBinding()]
param([switch]$NoOpen)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $projectRoot 'Battery.ps1')
. (Join-Path $projectRoot 'Smart.ps1')
function Invoke-LaptopScan {
$script:sections = [ordered]@{}
$script:findings = New-Object System.Collections.Generic.List[object]
function Finding($level, $message) { $script:findings.Add([pscustomobject]@{Level=$level;Message=$message}) }
function Collect($name, [scriptblock]$action) {
    Write-Verbose "Проверка: $name"
    try { $data = @(& $action); $script:sections[$name] = [pscustomobject]@{Status='OK';Data=$data;Error=$null} }
    catch { $script:sections[$name] = [pscustomobject]@{Status='Unavailable';Data=@();Error=$_.Exception.Message}; Finding 'UNKNOWN' "$name : данные недоступны — $($_.Exception.Message)" }
}
function Cim($class) { Get-CimInstance -ClassName $class -ErrorAction Stop }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$admin) { Finding 'INFO' 'Запуск без прав администратора: часть SMART, журналов и сведений может быть недоступна.' }
Collect 'Модель и BIOS' {
    Cim Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory,NumberOfLogicalProcessors
    Cim Win32_ComputerSystemProduct | Select-Object Vendor,Name,IdentifyingNumber,UUID
    Cim Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate,SerialNumber
}
Collect 'Windows' { Cim Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,InstallDate,LastBootUpTime,FreePhysicalMemory }
Collect 'Процессор' { Cim Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed,CurrentClockSpeed,Status }
Collect 'Оперативная память' {
    Cim Win32_PhysicalMemory | Select-Object DeviceLocator,Manufacturer,PartNumber,SerialNumber,Capacity,Speed,ConfiguredClockSpeed
    Cim Win32_PhysicalMemoryArray | Select-Object MemoryDevices,MaxCapacity,MemoryErrorCorrection
}
Collect 'Видеокарты' { Cim Win32_VideoController | Select-Object Name,DriverVersion,DriverDate,VideoModeDescription,Status,ConfigManagerErrorCode }
Collect 'Диски' { Cim Win32_DiskDrive | Select-Object Model,SerialNumber,Size,InterfaceType,MediaType,Status,FirmwareRevision }
Collect 'Разделы и свободное место' { Get-Volume | Select-Object DriveLetter,FileSystemLabel,FileSystem,HealthStatus,OperationalStatus,Size,SizeRemaining }
Collect 'Состояние физических дисков' {
    $disks = @(Get-PhysicalDisk)
    if (!$disks.Count) { throw 'Windows не вернула физические диски.' }
    foreach ($disk in $disks) {
        if ([string]$disk.HealthStatus -ne 'Healthy') { Finding 'WARN' "Диск $($disk.FriendlyName): HealthStatus=$($disk.HealthStatus)" }
        $disk | Select-Object DeviceId,FriendlyName,SerialNumber,MediaType,BusType,Size,HealthStatus,OperationalStatus
    }
}
Collect 'Счётчики надёжности дисков' {
    foreach ($disk in Get-PhysicalDisk) {
        try {
            $r = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop
            if ($null -eq $r) { throw "Нет счётчиков для $($disk.FriendlyName)" }
            if ($r.ReadErrorsUncorrected -gt 0 -or $r.WriteErrorsUncorrected -gt 0) { Finding 'WARN' "Диск $($disk.FriendlyName): неисправленные ошибки чтения/записи." }
            $r | Select-Object DeviceId,Temperature,TemperatureMax,Wear,PowerOnHours,ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected
        } catch {
            Finding 'UNKNOWN' "Счётчики $($disk.FriendlyName): $($_.Exception.Message)"
            [pscustomobject]@{DeviceId=$disk.DeviceId;Error=$_.Exception.Message}
        }
    }
}
Collect 'SMART PredictFailure' {
    $items = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus)
    if (!$items.Count) { throw 'SMART через WMI не поддерживается; это не означает исправность диска.' }
    foreach ($item in $items) {
        if ($item.PredictFailure) { Finding 'CRITICAL' "SMART прогнозирует отказ: $($item.InstanceName)" }
        $item | Select-Object InstanceName,PredictFailure,Reason
    }
}
Collect 'SMART напрямую' {
    foreach ($disk in Get-LaptopSmartData -ProjectRoot $projectRoot) {
        $name = $(if ($disk.Model) { $disk.Model } else { $disk.Device })
        if ($disk.HealthPassed -eq $false -or ($null -ne $disk.CriticalWarning -and $disk.CriticalWarning -gt 0)) { Finding 'CRITICAL' "Диск $name : SMART сообщает о неисправности / критическом предупреждении $($disk.CriticalWarning)." }
        if ($null -ne $disk.MediaErrors -and $disk.MediaErrors -gt 0) { Finding 'WARN' "Диск $name : ошибок данных в SMART — $($disk.MediaErrors)." }
        if ($disk.PendingSectors -gt 0 -or $disk.OfflineUncorrectable -gt 0 -or $disk.ReallocatedSectors -gt 0) { Finding 'WARN' "Диск $name : переназначено секторов $($disk.ReallocatedSectors), нестабильных $($disk.PendingSectors), неисправимых $($disk.OfflineUncorrectable)." }
        if ($null -ne $disk.PercentageUsed -and $disk.PercentageUsed -ge 80) { Finding 'WARN' "Диск $name : использовано $($disk.PercentageUsed)% ресурса SSD." }
        if ($disk.Error) { Finding 'UNKNOWN' "Диск $name : $($disk.Error)" }
        $disk
    }
}
# Use Windows wear only when no direct SMART endurance counter is available.
foreach ($counter in $script:sections['Счётчики надёжности дисков'].Data) {
    if ($null -eq $counter.Wear -or $counter.Wear -lt 80) { continue }
    $physical = $script:sections['Состояние физических дисков'].Data | Where-Object { $_.DeviceId -eq $counter.DeviceId } | Select-Object -First 1
    $serial = ([string]$physical.SerialNumber).Trim()
    $directWear = @($script:sections['SMART напрямую'].Data | Where-Object { $serial -and ([string]$_.SerialNumber).Trim() -eq $serial -and $null -ne $_.PercentageUsed })
    if (!$directWear.Count) { Finding 'WARN' "Диск $($physical.FriendlyName): Windows сообщает об износе $($counter.Wear)%." }
}
Collect 'Аккумулятор Windows' {
    $b = @(Cim Win32_Battery)
    if (!$b.Count) { throw 'Аккумулятор не обнаружен.' }
    $b | Select-Object Name,Status,BatteryStatus,EstimatedChargeRemaining,EstimatedRunTime,DesignCapacity,FullChargeCapacity
}
Collect 'Ёмкость аккумулятора' {
    $capacity = @(Get-LaptopBatteryCapacity)
    foreach ($battery in $capacity) {
        if ($null -eq $battery.RemainingCapacityPercent) { Finding 'UNKNOWN' "Нет ёмкости батареи $($battery.Battery)." }
        elseif ($battery.RemainingCapacityPercent -lt 70) { Finding 'WARN' "Батарея $($battery.Battery): осталось $($battery.RemainingCapacityPercent)% проектной ёмкости." }
        $battery
    }
}
Collect 'Циклы аккумулятора' { Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount | Select-Object InstanceName,CycleCount }
Collect 'Датчики ACPI' {
    $temps = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature)
    if (!$temps.Count) { throw 'ACPI-датчики недоступны.' }
    foreach ($t in $temps) { [pscustomobject]@{Zone=$t.InstanceName;Celsius=[math]::Round($t.CurrentTemperature / 10 - 273.15,1);Note='Температура зоны ACPI, не обязательно CPU/GPU'} }
}
Collect 'Устройства с ошибками' {
    $bad = @(Cim Win32_PnPEntity | Where-Object { $null -ne $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
    foreach ($b in $bad) { Finding 'WARN' "Устройство: $($b.Name), код ошибки $($b.ConfigManagerErrorCode). Возможна проблема драйвера." }
    $bad | Select-Object Name,PNPClass,ConfigManagerErrorCode,Status
}
Collect 'Сетевые адаптеры' { Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress }
Collect 'Экраны' { Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID | Select-Object InstanceName,Active,ManufacturerName,ProductCodeID,SerialNumberID }
Collect 'Камера, звук, Bluetooth, USB' { Cim Win32_PnPEntity | Where-Object { $_.PNPClass -in @('Camera','Image','Media','AudioEndpoint','Bluetooth','USB') } | Select-Object Name,PNPClass,Status,ConfigManagerErrorCode }
Collect 'Ошибки системы за 30 дней' {
    $events = @()
    try { $events = @(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddDays(-30);Level=@(1,2)} -MaxEvents 300 -ErrorAction Stop) }
    catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    foreach ($e in $events) {
        if ($e.ProviderName -match 'WHEA|disk|storahci|stornvme|Ntfs' ) { Finding 'WARN' "Журнал: $($e.ProviderName), событие $($e.Id), $($e.TimeCreated). Требуется изучить сообщение." }
    }
    $events | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message
}
Finding 'INFO' 'Отсутствие предупреждений не доказывает исправность. Недоступные данные и пустые счётчики нельзя считать успешным тестом.'
$report = [ordered]@{Created=(Get-Date).ToString('o');Computer=$env:COMPUTERNAME;Administrator=$admin;Findings=@($script:findings.ToArray());Sections=$script:sections}

return ($report | ConvertTo-Json -Depth 12 -Compress)
}
$template = [IO.File]::ReadAllText((Join-Path $projectRoot 'interface.html'))
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('null'))
$page = $template.Replace('__DATA_BASE64__', $payload)
. (Join-Path $projectRoot 'Serve-Page.ps1')
