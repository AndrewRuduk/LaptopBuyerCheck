#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Battery.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('LaptopBuyerCheck-test-' + [guid]::NewGuid().ToString('N') + '.xml')
try {
    @'
<BatteryReport xmlns="urn:sample"><Batteries>
<Battery><Id>A</Id><DesignCapacity>50000</DesignCapacity><FullChargeCapacity>40000</FullChargeCapacity><CycleCount>0</CycleCount></Battery>
<Battery><Id>B</Id><DesignCapacity>0</DesignCapacity><FullChargeCapacity>20000</FullChargeCapacity><CycleCount>-</CycleCount></Battery>
</Batteries></BatteryReport>
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
    $rows = @(ConvertFrom-LaptopBatteryXml -Path $fixture)
    if ($rows.Count -ne 2 -or $rows[0].RemainingCapacityPercent -ne 80 -or $rows[0].CycleCount -ne 0) { throw 'Valid battery/namespace/zero-cycle test failed.' }
    if ($null -ne $rows[1].RemainingCapacityPercent -or $null -ne $rows[1].CycleCount) { throw 'Missing data must stay unknown.' }
    '<BatteryReport><Batteries><Battery><Id>C</Id><DesignCapacity>-</DesignCapacity><FullChargeCapacity>-</FullChargeCapacity></Battery></Batteries></BatteryReport>' | Set-Content -LiteralPath $fixture -Encoding UTF8
    $rows = @(ConvertFrom-LaptopBatteryXml -Path $fixture)
    if ($null -ne $rows[0].RemainingCapacityPercent) { throw 'Unavailable capacity test failed.' }
    '<BatteryReport><Batteries/></BatteryReport>' | Set-Content -LiteralPath $fixture -Encoding UTF8
    $rejected = $false
    try { ConvertFrom-LaptopBatteryXml -Path $fixture | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Empty battery list must be rejected.' }
    '<!DOCTYPE BatteryReport [<!ENTITY x "data">]><BatteryReport><Batteries/></BatteryReport>' | Set-Content -LiteralPath $fixture -Encoding UTF8
    $rejected = $false
    try { ConvertFrom-LaptopBatteryXml -Path $fixture | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'DTD must be rejected.' }
    Write-Host 'Battery XML tests passed.'
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force } }
