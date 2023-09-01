<#
    .SYNOPSIS
    This script checks some parameters of a DELL PowerStore storage.
    It collects information per rest-api and creates a PRTG compatible XML return.

    .PARAMETER DeviceName
    FQDN or IP-Address of the PowerStore appliance
    This parameter is mandantory.

    .PARAMETER SensorType
    Defines the Sensor Type in PRTG
    Device      = Gets device infos, events and alerts
    Capacity    = Gets some capacity related metrics
    Performance = Gets some performance related metrics
    This parameter is mandantory.

    .PARAMETER UserName
    Username to login on the PowerStore
    This parameter is mandantory.

    .PARAMETER Password
    Password to login on the PowerStore
    This parameter is mandantory.

    .PARAMETER nossl
    This switch parameter is used if the PowerStore has no SSL certificate installed.
    Do not use it in production. All the communication will be unencrypted.
    This parameter is optional.

    .INPUTS
    None

    .OUTPUTS
    This script retrives an xml file and parses it to PRTG

    .LINK
    https://raw.githubusercontent.com/tn-ict/Public/master/Disclaimer/DISCLAIMER

    .NOTES
    Author  : Andreas Bucher
    Version : 0.2.0
    Purpose : Get PRTG-formatted information from a Dell PowerStore via rest-api

    .EXAMPLE
    Create a new user with Operator role on the Powerstore. Use this user and password as parameter
    Create a new sensor on PRTG:
    -DeviceName '%host' -SensorType 'SensorType' -Username '%windowsuser' -Password '%windowspassword' (-nossl)
    Those %-parameters are retreived from the PRTG WebGUI

    Try it standalone
    .\Check-PoweerStore-PRTG.ps1 -DeviceName "fqdn" -SensorType "SensorType" -UserName "UserName" -Password "Password" -nossl

#>
#----------------------------------------------------------[Declarations]----------------------------------------------------------
# Declare input parameters
Param(
    [Parameter(Mandatory=$true)]
    [string]$DeviceName,
    [Parameter(Mandatory=$true)]
    [string]$SensorType,
    [Parameter(Mandatory=$true)]
    [string]$UserName,
    [Parameter(Mandatory=$true)]
    [string]$Password,
    [switch]$nossl
    )

# Dirty fix if PowerStore is not secured with ssl certificate
if ($nossl) {
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;

        public class IDontCarePolicy : ICertificatePolicy {
        public IDontCarePolicy() {}
        public bool CheckValidationResult(
            ServicePoint sPoint, X509Certificate cert,
            WebRequest wRequest, int certProb) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = new-object IDontCarePolicy
}

# Variables
$baseurl     = "https://$DeviceName/api/rest/"
$UpdatePath  = "https://raw.githubusercontent.com/buesche87/PRTG.Dell.PowerStore/main/Check-PowerStore-PRTG.ps1"

# Create credentials
$secpassword = ConvertTo-SecureString $Password -AsPlainText -Force
$reqcred     = New-Object System.Management.Automation.PSCredential ($UserName, $secpassword)

## Create basic auth token (base64)
$pair  = "$($UserName):$($Password)"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$token = [System.Convert]::ToBase64String($bytes)

# Get DELL-EMC-TOKEN and cookie (TODO: is there another solution?)
$resource     = "login_session"
$uri          = $baseurl + $resource
$request      = Invoke-WebRequest -Uri $uri -Credential $reqcred | Select-Object headers
$apitoken     = $request.Headers.Values | Select-Object -First 1
$cookie,$null = ($request.Headers.Values | Select-Object -Last 1 ).Split(';')

 # Create headers for GET requests
$getheaders = @{
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
    "Authorization" = "Basic $token"
 }

 # Create headers for POST requests
 $postheaders = @{
    "DELL-EMC-TOKEN" = "$apitoken"
    "Content-Type"   = "application/json"
    "Authorization"  = "Basic $token"
    "User-Agent"     = "PRTGPowerStoreSensor/0.1"
    "Accept"         = "*/*"
    "Cookie"         = "$cookie"
}
#-----------------------------------------------------------[Functions]------------------------------------------------------------
# GET Webrequest
function Get-Info {
    param(
        $resource
    )

    # Merge url and send webrequest
    $uri    = $baseurl + $resource
    try {
        $answer    = Invoke-RestMethod -Method 'Get' -Uri $uri -Headers $getheaders -ContentType "application/json"
    }
    catch {
        $errmsg    = $_.Exception.Response.StatusDescription
        $errdetail = ($_.ErrorDetails.Message | ConvertFrom-Json).messages.message_l10n
    }

    if ($answer) { Return $answer }
    else { Set-ErrorOutput "Request auf $uri fehlgeschlagen: $errmsg - $errdetail" }
 }
# POST Webrequest
function Post-Info {
    param(
        $resource,
        $body
    )

    # Merge url and send webrequest
    $uri    = $baseurl + $resource
    try {
        $answer    = Invoke-RestMethod -Method 'Post' -Uri $uri -Headers $postheaders -Body $body -ContentType "application/json"
    }
    catch {
        $errmsg    = $_.Exception.Response.StatusDescription
        $errdetail = ($_.ErrorDetails.Message | ConvertFrom-Json).messages.message_l10n
    }

    if ($answer) { Return $answer }
    else { Set-ErrorOutput "Request auf $uri fehlgeschlagen: $errmsg - $errdetail" }
 }
# Get device id
function Get-DeviceId {
    # Get appliance info
    $resource  = "appliance?select=id,name"
    $appliance = Get-Info $resource
    Return $appliance.id
}
# Find Major alerts in Events
function Get-EventInfos {
    param(
        $eventinfo
    )

    # Find major events
    $msg = ""
    $msg = ($eventinfo | Where-Object { $_.severity -like "Major" -and $_.description_l10n -notlike "*node port cabling*" } | Select-Object -First 1).description_l10n

    if ($msg) { Return $msg }
    else      { Return "OK" }
}
# Check for hardware errors
function Get-HWInfos {
    param(
        $hardware
    )

    # Find hardware alerts
    $msg = ""
    foreach ($device in $hardware) {

        if ($device.lifecycle_state -ne "Healthy" -and $device.lifecycle_state -ne "Empty" -and $null -ne $device.lifecycle_state) {
            $msg = $msg + "${$device.type}: ${$device.name} ${$device.lifecycle_state} - Partnumber: ${$device.part_number} / Serialnumber: ${$device.serial_number}`n"
        }
    }

    if ($msg) { Return $msg }
    else      { Return "Healthy" }
}
# Get Device infos for Device-Sensor
function Get-DeviceInfos {

    # Define Device object and parameters
    $Device = [PSCustomObject]@{
        Event      = ""
        EStatus    = 0
        HWMsg      = ""
        HWStatus   = 0
        Text       = ""
    }

    # Events
    $resource = "event?select=id,severity,resource_type,generated_timestamp,description_l10n?order=generated_timestamp.desc"
    $events   = Get-Info $resource

    # Hardware
    $resource = "hardware?select=id,name,type,lifecycle_state,part_number,serial_number"
    $hardware = Get-Info $resource

    # Fill up object
    $Device.Event = Get-EventInfos $events
    $Device.HWMsg = Get-HWInfos $hardware

    # Set error-status
    if ($Device.Event -ne "OK")      { $Device.EStatus = 1 }
    if ($Device.HWMsg -ne "Healthy") { $Device.HWStatus = 1 }
    
    # Create Text for PRTG
    $Device.Text = "Hardware: $($Device.HWMsg) - Events: $($Device.Event)"

    Return $Device
}
# Get Capacity infos for Capacity-Sensor
function Get-CapacityInfos {

    # Define capacity object and parameters
    $Capacity = [PSCustomObject]@{
        Total       = 0
        Free        = 0
        FreePercent = 0
        Used        = 0
        UsedPercent = 0
        DRR         = 0
        Msg         = ""
    }

    # Get device ID
    $devid = Get-DeviceId

    # Set metrics resource
    $resource = "metrics/generate"

    # Define body for webrequest
    $body = (convertto-json @{
        entity="space_metrics_by_appliance"
        entity_id="$devid"
        interval="One_Hour"
    })

    # Send request to device and get answer
    $allspacemetrics = Post-Info $resource $body
    $spacemetrics    = $allspacemetrics | Sort-Object -Property timestamp -Descending | Select-Object -First 1

    # Fill up object
    $Capacity.Total       = [Math]::Round([Decimal]$spacemetrics.last_physical_total/1TB, 1)
    $Capacity.Free        = [Math]::Round([Decimal](($spacemetrics.last_physical_total - $spacemetrics.last_physical_used)/1TB), 1)
    $Capacity.FreePercent = [Math]::Round([Decimal]((($spacemetrics.last_physical_total - $spacemetrics.last_physical_used)/$spacemetrics.last_physical_total)*100),1)
    $Capacity.Used        = [Math]::Round([Decimal]$spacemetrics.last_physical_used/1TB, 1)
    $Capacity.UsedPercent = 100 - $Capacity.FreePercent
    $Capacity.DRR         = [Math]::Round([Decimal]$spacemetrics.last_data_reduction,1)

    Return $Capacity
}
# Get Performance infos for Performance-Sensor
function Get-PerformanceInfos {

    # Define Performance object and parameters
    $Performance = [PSCustomObject]@{
        BWRead   = 0
        BWWrite  = 0
        LatRead  = 0
        LatWrite = 0
        ReadOps  = 0
        WriteOps = 0
    }

    # Get device ID
    $devid = Get-DeviceId

    # Performance metrics
    $resource = "metrics/generate"

    # Define body for webrequest
    $body = (convertto-json @{
        entity="performance_metrics_by_appliance"
        entity_id="$devid"
        interval="One_Hour"
    })

    # Send request to device
    $allperfmetrics = Post-Info $resource $body
    $perfmetrics = $allperfmetrics | Sort-Object -Property timestamp -Descending | Select-Object -First 1

    # Fill up object
    $Performance.BWRead   = [Math]::Round([Decimal]$perfmetrics.avg_read_bandwidth/1MB,1)
    $Performance.BWWrite  = [Math]::Round([Decimal]$perfmetrics.avg_write_bandwidth/1MB,1)
    $Performance.LatRead  = [Math]::Round([Decimal]$perfmetrics.avg_read_latency/1000,2)
    $Performance.LatWrite = [Math]::Round([Decimal]$perfmetrics.avg_write_latency/1000,2)
    $Performance.ReadOps  = [Math]::Round([Decimal]$perfmetrics.avg_read_iops,1)
    $Performance.WriteOps = [Math]::Round([Decimal]$perfmetrics.avg_write_iops,1)

    Return $Performance
}
# Return Error-XML
function Set-ErrorOutput {
    param(
        $msg
    )

    Write-Output '<?xml version="1.0" encoding="UTF-8" ?>'
    Write-Output "<prtg>"
    Write-Output "<error>1</error>"
    Write-Output "<text>$msg</text>"
    Write-Output "</prtg>"

    return $ErrorXML
    exit 1

}
# Return Device XML
function Set-DeviceOutput {
    param(
        $Device
    )

    # Create XML-Content
    Write-Output '<?xml version="1.0" encoding="UTF-8" ?>'
    Write-Output "<prtg>"

    Write-Output    "<Text>$($Device.Text)</Text>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Events</channel>"
    Write-Output    "  <value>$($Device.EStatus)</value>"
    Write-Output    "  <LimitMaxError>1</LimitMaxError>"
    Write-Output    "  <LimitErrorMsg>Major Error in Eventlog</LimitErrorMsg>"
    Write-Output    "  <LimitMode>1</LimitMode>"
    Write-Output    "  <showChart>1</showChart>"
    Write-Output    "  <showTable>1</showTable>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Status</channel>"
    Write-Output    "  <value>$($Device.HWStatus)</value>"
    Write-Output    "  <LimitMaxError>1</LimitMaxError>"
    Write-Output    "  <LimitErrorMsg>Hardwarestatus degraded</LimitErrorMsg>"
    Write-Output    "  <LimitMode>1</LimitMode>"
    Write-Output    "  <showChart>1</showChart>"
    Write-Output    "  <showTable>1</showTable>"
    Write-Output    "</result>"

    Write-Output "</prtg>"
}
# Return Capacity XML
function Set-CapacityOutput {
    param(
        $Capacity
    )

    # Create XML-Content
    Write-Output '<?xml version="1.0" encoding="UTF-8" ?>'
    Write-Output "<prtg>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Total Space</channel>"
    Write-Output    "  <value>$($Capacity.Total)</value>"
    Write-Output    "  <CustomUnit>TB</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Free Space</channel>"
    Write-Output    "  <value>$($Capacity.Free)</value>"
    Write-Output    "  <CustomUnit>TB</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Free %</channel>"
    Write-Output    "  <value>$($Capacity.FreePercent)</value>"
    Write-Output    "  <CustomUnit>%</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "  <LimitMinWarning>20</LimitMinWarning>"
    Write-Output    "  <LimitWarningMsg>Freier Speicher unter 20%</LimitWarningMsg>"
    Write-Output    "  <LimitMinError>10</LimitMinError>"
    Write-Output    "  <LimitErrorMsg>Freier Speicher unter 10%</LimitErrorMsg>"
    Write-Output    "  <LimitMode>1</LimitMode>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Used Space</channel>"
    Write-Output    "  <value>$($Capacity.Used)</value>"
    Write-Output    "  <CustomUnit>TB</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Used %</channel>"
    Write-Output    "  <value>$($Capacity.UsedPercent)</value>"
    Write-Output    "  <CustomUnit>%</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Data Reduction Rate</channel>"
    Write-Output    "  <value>$($Capacity.DRR)</value>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output "</prtg>"
}
# Return Performance XML
function Set-PerformanceOutput {
    param(
        $Performance
    )

    # Create XML-Content
    Write-Output '<?xml version="1.0" encoding="UTF-8" ?>'
    Write-Output "<prtg>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Read Bandwith</channel>"
    Write-Output    "  <value>$($Performance.BWRead)</value>"
    Write-Output    "  <CustomUnit>MB/s</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Write Bandwith</channel>"
    Write-Output    "  <value>$($Performance.BWWrite)</value>"
    Write-Output    "  <CustomUnit>MB/s</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Read Latency</channel>"
    Write-Output    "  <value>$($Performance.LatRead)</value>"
    Write-Output    "  <CustomUnit>ms</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Write Latency</channel>"
    Write-Output    "  <value>$($Performance.LatWrite)</value>"
    Write-Output    "  <CustomUnit>ms</CustomUnit>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Read IOPS</channel>"
    Write-Output    "  <value>$($Performance.ReadOps)</value>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output    "<result>"
    Write-Output    "  <channel>Write IOPS</channel>"
    Write-Output    "  <value>$($Performance.WriteOPS)</value>"
    Write-Output    "  <Float>1</Float>"
    Write-Output    "</result>"

    Write-Output "</prtg>"
}
# Update Script
function Get-NewScript {

    # Check if Update-Script is reachable
    $StatusCode = Invoke-WebRequest $UpdatePath -UseBasicParsing | ForEach-Object {$_.StatusCode}
    $CurrentScript = $PSCommandPath

    if ($StatusCode -eq 200 ) {

        # Parse version string of script on github
        $UpdateScriptcontent = (Invoke-webrequest -URI $UpdatePath -UseBasicParsing).Content
        $newversionstring    = ($UpdateScriptcontent | Select-String "Version :.*" | Select-Object -First 1).Matches.Value
        $newversion          = $newversionstring -replace '[^0-9"."]',''

        # Parse version string of current script
        $CurrentScriptContent = Get-Content -Path $PSCommandPath -Encoding UTF8 -Raw
        $currentversionstring = ($CurrentScriptContent | Select-String "Version :.*" | Select-Object -First 1).Matches.Value
        $currentversion       = $currentversionstring -replace '[^0-9"."]',''

        # Replace and re-run script if update-script is newer
        if ([version]$newversion -gt [version]$currentversion) {

            # Create temp directory if it does not exists
            $tmpdirectory = "C:\Temp"
            if(-not (test-path $tmpdirectory)){ New-Item -Path $tmpdirectory -ItemType Directory }

            # Create a temporary file with content of the new script
            $tempfile = "$tmpdirectory\update-script.new"
            Invoke-WebRequest -URI $UpdatePath -outfile $tempfile

            # Replace current script
            $content = Get-Content $tempfile -Encoding utf8 -raw
            $content | Set-Content $CurrentScript -encoding UTF8

            # Remove temporary file
            Remove-Item $tempfile

            # Call new script
            &$CurrentScript $script:args
        }
    }
}
#-----------------------------------------------------------[Execute]------------------------------------------------------------
# Autoupdate script
Get-NewScript

# Get infos for sensortype Device
if ($SensorType -eq "Device") {
    $data = Get-DeviceInfos
    Set-DeviceOutput $data
}

# Get infos for sensortype Capacity
elseif ($SensorType -eq "Capacity") {
    $data = Get-CapacityInfos
    Set-CapacityOutput $data
}

# Get infos for sensortype Performance
elseif ($SensorType -eq "Performance") {
    $data = Get-PerformanceInfos
    Set-PerformanceOutput $data
}

# Get return error message
else {

    $msg = "Script-Parameter prüfen"
    Set-ErrorOutput $msg
}
