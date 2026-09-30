#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Smart.ps1')
function Assert($condition, $message) { if (!$condition) { throw $message } }
$nvme = @'
{"smartctl":{"exit_status":0},"device":{"protocol":"NVMe"},"model_name":"Sample SSD","serial_number":"A","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"percentage_used":7,"power_on_hours":789,"temperature":29,"media_errors":0,"num_err_log_entries":12,"data_units_written":31769769,"unsafe_shutdowns":0}}
'@ | ConvertFrom-Json
$result = ConvertFrom-LaptopSmartData -Data $nvme -Device '/dev/sda' -DeviceType 'nvme'
Assert ($result.RemainingLifePercent -eq 93 -and $result.PowerOnHours -eq 789) 'NVMe endurance/hours incorrect.'
Assert ($result.MediaErrors -eq 0 -and $result.ErrorLogEntries -eq 12) 'Error log entries must not be mixed with media errors.'
Assert ($result.BytesWritten -eq 16266121728000) 'NVMe data-unit conversion incorrect.'
Assert ($result.HealthPassed -eq $true -and !$result.Error) 'Valid SMART data rejected.'
$nvme.smartctl.exit_status = 8
$nvme.smart_status.passed = $false
$result = ConvertFrom-LaptopSmartData -Data $nvme -Device '/dev/sda'
Assert ($result.HealthPassed -eq $false -and $result.PowerOnHours -eq 789 -and !$result.Error) 'Failing health exit bit must preserve data.'
$nvme.nvme_smart_health_information_log.percentage_used = 105
$result = ConvertFrom-LaptopSmartData -Data $nvme -Device '/dev/sda'
Assert ($result.RemainingLifePercent -eq 0 -and $result.PercentageUsed -eq 105) 'Endurance beyond 100 must remain exhausted.'
$ata = @'
{"smartctl":{"exit_status":0},"device":{"protocol":"ATA"},"smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":9,"name":"Power_On_Hours","raw":{"value":1234}},{"id":5,"name":"Reallocated_Sector_Ct","raw":{"value":3}},{"id":197,"name":"Current_Pending_Sector","raw":{"value":1}},{"id":198,"name":"Offline_Uncorrectable","raw":{"value":0}}]}}
'@ | ConvertFrom-Json
$result = ConvertFrom-LaptopSmartData -Data $ata -Device '/dev/sdb'
Assert ($result.PowerOnHours -eq 1234 -and $result.PendingSectors -eq 1 -and $result.ReallocatedSectors -eq 3) 'ATA sector counters incorrect.'
Assert ($null -eq $result.RemainingLifePercent -and $null -eq $result.MediaErrors) 'Unknown HDD endurance/media errors must not become zero or 100%.'
$unknown = '{"smartctl":{"exit_status":2,"messages":[{"severity":"error","string":"Access denied"}]}}' | ConvertFrom-Json
$result = ConvertFrom-LaptopSmartData -Data $unknown -Device '/dev/sdc'
Assert ($result.Error -match 'Access denied' -and $null -eq $result.HealthPassed -and $null -eq $result.PowerOnHours) 'Access failure must stay unknown.'
$empty = '{"smartctl":{"exit_status":0}}' | ConvertFrom-Json
$result = ConvertFrom-LaptopSmartData -Data $empty -Device '/dev/sdd'
Assert ([bool]$result.Error) 'Empty response must not pass as SMART.'
Write-Host 'SMART parsing tests passed.'
