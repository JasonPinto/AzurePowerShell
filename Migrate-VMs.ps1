####################################################################################################################################
#                                                                                                                                  #
#                                                 Migrate-VMs.ps1 Version 1.7                                                      #
#                                                                                                                                  #
# Authored by: Mark Renoden - markreno@microsoft.com                                                                               #
#                                                                                                                                  #
# ******************************************************************************************************************************** #
# ***                                                                                                                          *** #
# ***                                                      WARNING                                                             *** #
# ***                                                                                                                          *** #
# *** This script deletes things! I take no responsibility if you run it without understanding what it does and why it does it *** #
# ***                                                                                                                          *** #
# ***                                                                                                                          *** #
# ***                                                                                                                          *** #
# ***                                                                                                                          *** #
# ******************************************************************************************************************************** #
#                                                                                                                                  #
# Version 1.7 updates - March 3rd 2015                                                                                             #
#     - Added validation of user-configured inputs                                                                                 #
#     - Added option to move cloud services, reserved IP addresses and affinity groups to the same data centre location            #
#            as the destination storage account                                                                                    #
#                                                                                                                                  #
# Version 1.6 updates - March 2nd 2015                                                                                             #
#     - Added handling for cases where cloud services are using affinity groups instead of locations or vnets                      #
#     - Script now creates the output directory it doesn't already exist                                                           #
#                                                                                                                                  #
# Version 1.5 updates - March 1st 2015                                                                                             #
#     - Added handling for cases where the VM is not attached to a defined VNet                                                    #
#     - Added handling for cases where the VM participates in an internal load balancer                                            #
#     - Utilizes Export-AzureVM writing serialized VM configuration to the output folder                                           #
#     - No longer assumes VM VHDs exist in the same storage account in the source subscription                                     #
#     - Added ability to specify the datacentre location for the destination storage account                                       #
#                                                                                                                                  #
# This script assumes                                                                                                              #
#     - Azure PowerShell version 0.8.14                                                                                            #
#     - Full admin control of the source and destination subscriptions already exists (publish settings files have been imported)  #
#     - The virtual networks in use by the VMs have been duplicated at the destination meaning                                     #
#          - Duplication of VNet name                                                                                              # 
#          - Duplication of IP ranges and subnet names/ranges                                                                      #
#     - ALL VHD BLOBs will be migrated to a container in the destination storage account with the same name as the source          #
#     - Cloud service names should remain the same -> they will be deleted from the source and recreated in the destination        #
#     - VM names should remain the same  -> they will be deleted from the source and recreated in the destination                  #
#     - Reserved IP addresses should remain the same -> they will be deleted form the source and recreated in the destination      #
#                                                                                                                                  #
# This script does not delete the VHD BLOBs from the source storage account                                                        #
# There are 6 items that need editing before this script will run for you and these are highlighted with                           #
#                                                                                                                                  #
#                                                ####### EDIT THIS!!!!! #######                                                    #
#                                                                                                                                  #
# If something goes wrong, your output folder will contain all configuration data for the deleted VMs and cloud services           #
#                                                                                                                                  #
####################################################################################################################################

#Define data collection directory
$outputDir = '<OUTPUT DIRECTORY FOR CAPTURED VM CONFIGURATION>'                                       ####### EDIT THIS!!!!! #######
Write-Host
Write-Host 'Output directory is ' -ForegroundColor Green -NoNewline
Write-Host $outputDir -ForegroundColor Cyan
If (!(Test-Path -Path $outputDir -IsValid))
{
    Write-Host $outputDir -ForegroundColor Cyan -NoNewline
    Write-Host ' is not a valid path syntax. Exiting.' -ForegroundColor Red
    exit;
}
Else
{
    If (!(Test-Path -Path $outputDir))
    {
        New-Item -Path $outputDir -ItemType Directory
    }
}

#Define source subscription
$sourceSubscriptionName = '<SUBSCRIPTION NAME WHERE VMs CURRENTLY RESIDE>'                            ####### EDIT THIS!!!!! #######
Write-Host
Write-Host 'Source subscription is ' -ForegroundColor Green -NoNewline
Write-Host $sourceSubscriptionName -ForegroundColor Cyan
If (!(Get-AzureSubscription -SubscriptionName $sourceSubscriptionName))
{
    Write-Host $sourceSubscriptionName -ForegroundColor Cyan -NoNewline
    Write-Host ' is not a valid subscription. Exiting.' -ForegroundColor Red
    exit;
}

#Define destination subscription and storage account
$destinationSubscriptionName = '<SUBSCRIPTION NAME WHERE VMs WILL RESIDE AFTER MIGRATION>'            ####### EDIT THIS!!!!! #######
$destinationStorageAccount = '<STORAGE ACCOUNT NAME WHERE VHD BLOBs WILL RESIDE AFTER MIGRATION>'     ####### EDIT THIS!!!!! #######
$destinationStorageAccountLocation = '<DATACENTRE LOCATION FOR DESTINATION STORAGE ACCOUNT>'          ####### EDIT THIS!!!!! #######
#######       $destinationStorageLocation should have one of the Name values returned by Get-AzureLocation | ft Name         #######
Write-Host
Write-Host 'Destination subscription is ' -ForegroundColor Green -NoNewline
Write-Host $destinationSubscriptionName -ForegroundColor Cyan
If (!(Get-AzureSubscription -SubscriptionName $destinationSubscriptionName))
{
    Write-Host $destinationSubscriptionName -ForegroundColor Cyan -NoNewline
    Write-Host ' is not a valid subscription. Exiting.' -ForegroundColor Red
    exit;
}
$pattern = "^([a-z0-9]{3,24})$"
Write-Host 'Destination storage account is ' -ForegroundColor Green -NoNewline
Write-Host $destinationStorageAccount -ForegroundColor Cyan
If (!($destinationStorageAccount -cmatch $pattern))
{
    Write-Host $destinationStorageAccount -ForegroundColor Cyan -NoNewline
    Write-Host ' is not a valid storage account name.' -ForegroundColor Red
    Write-Host 'Storage account names must be 3 to 24 lower-case alphanumeric characters. Exiting' -ForegroundColor Red
    exit;
}
Write-Host 'Destination storage account location is ' -ForegroundColor Green -NoNewline
Write-Host $destinationStorageAccountLocation -ForegroundColor Cyan
If (!(get-azurelocation | where {$_.Name -eq $destinationStorageAccountLocation}))
{
    Write-Host $destinationStorageAccountLocation -ForegroundColor Cyan -NoNewline
    Write-Host ' is not a valid data centre location.' -ForegroundColor Red
    Write-Host 'Use Get-AzureLocation to list valid data centre locations. Exiting' -ForegroundColor Red
    exit;
}

#Select source subscription
Select-AzureSubscription -SubscriptionName $sourceSubscriptionName
Write-Host
Write-Host 'Selecting source subscription ' -ForegroundColor Green -NoNewline
Write-Host $sourceSubscriptionName -ForegroundColor Cyan

#Define an array of VMs that will be excluded from migration
$excludedVMs = ('vmA','vmB','vmF')                                                                    ####### EDIT THIS!!!!! #######
Write-Host
Write-Host 'VMs not being migrated -' -ForegroundColor Green
foreach ($evm in $excludedVMs)
{
    Write-Host '   '$evm -ForegroundColor Cyan
}

#Retrieve VMs
$vms = Get-AzureVM | where {$excludedVMs -notcontains $_.Name}
Write-Host
Write-Host 'VMs being migrated -' -ForegroundColor Green
foreach ($vm in $vms)
{
    Write-Host '   '$vm.Name -ForegroundColor Cyan
}

#Check VMs to be migrated don't belong to a cloud service that houses a VM not being migrated
foreach ($vm in $vms)
{
    $csvms = Get-AzureVM -ServiceName $vm.ServiceName
    foreach ($csvm in $csvms)
    {
        If ($excludedVMs -contains $csvm.Name)
        {
            Write-Host
            Write-Host 'Cloud service ' -ForegroundColor Red -NoNewline
            Write-Host $vm.ServiceName -ForegroundColor Cyan -NoNewline
            Write-Host ' hosting VM ' -ForegroundColor Red -NoNewline
            Write-Host $vm.Name -ForegroundColor Cyan -NoNewline
            Write-Host ' also contains VM ' -ForegroundColor Red -NoNewline
            Write-Host $csvm.Name -ForegroundColor Cyan -NoNewline
            Write-Host '. All VMs residing in the same cloud service must be migrated. Exiting' -ForegroundColor Red -NoNewline
            exit;
        }
    }
}

#Offer choice to keep data centre locations or to use the destination storage account location
Write-Host
Write-Host "If you would like cloud services, affinity groups and reserved IP addresses to maintain their data centre location, type " -ForegroundColor Green -NoNewline
Write-Host "'keep'" -ForegroundColor Yellow -NoNewline
Write-Host "." -ForegroundColor Green
Write-Host " Otherwise, these objects will inherit the destination storage group data centre location." -ForegroundColor Green
If ((Read-Host " ") -ne 'keep')
{
    $keep = $false
}
Else
{
    $keep = $true
}

Write-Host
Write-Host "If these choices are correct, Press 'y' to continue. " -ForegroundColor Yellow -NoNewline
Write-Host "NOTE: Proceeding will delete deployments from the source subscription!" -ForegroundColor Red
If ((Read-Host " ") -ne 'y')
{
    exit;
}

#Collect pertinent information about each VM
$vmInfo = @()

foreach ($vm in $vms)
{
    #Export VM config to the output directory
    $exportPath = $outputDir+'\'+$vm.Name+'.xml'
    Write-Host
    Write-Host 'Exporting VM to ' -ForegroundColor Green -NoNewline
    Write-Host $exportPath -ForegroundColor Cyan
    Export-AzureVM -ServiceName $vm.ServiceName -Name $vm.Name -Path $exportPath | Out-Null
    
    #Build object that will store VM information
    $info = "" | Select-Object ExportPath, ServiceName, ServiceLocation, ServiceAffinityGroup, ServiceAffinityGroupLocation, InternalLoadBalancers, ReservedIPAddressName, ReservedIPAddressLabel, ReservedIPAddressLocation, VNet, OSDisk, DataDisks

    #Populate VM information
    $info.ExportPath = $exportPath
    $info.ServiceName = $vm.ServiceName
    If ($keep)
    {
        $info.ServiceLocation = (Get-AzureService -ServiceName $vm.ServiceName).Location
    }
    Else
    {
        If ((Get-AzureService -ServiceName $vm.ServiceName).Location)
        {
            $info.ServiceLocation = $destinationStorageAccountLocation
        }
    }
    $info.ServiceAffinityGroup = (Get-AzureService -ServiceName $vm.ServiceName).AffinityGroup
    If ($info.ServiceAffinityGroup)
    {
        If ($keep)
        {
            $info.ServiceAffinityGroupLocation = (Get-AzureAffinityGroup -Name $info.ServiceAffinityGroup).Location
        }
        Else
        {
            $info.ServiceAffinityGroupLocation = $destinationStorageAccountLocation
        }
    }
    $info.InternalLoadBalancers = (Get-AzureInternalLoadBalancer -ServiceName $vm.ServiceName)
    $rIP = (Get-AzureReservedIP | where {$_.ServiceName -eq $vm.ServiceName})
    If ($rIP)
    {
        $info.ReservedIPAddressName = $rIP.ReservedIPName
        $info.ReservedIPAddressLabel = $rIP.Label
        $info.ReservedIPAddressLocation = $rIP.Location
    }
    $info.VNet = $vm.VirtualNetworkName
    $info.OSDisk = $vm | Get-AzureOSDisk
    $info.DataDisks = $vm | Get-AzureDataDisk

    #Add VM information to the $vmInfo array
    $vmInfo += $info
}

#Write VM Configuration Information to a backup file
$vmInfo | Export-Clixml -Path $outputDir'\vmInfo.xml'
Write-Host
Write-Host 'VM information collected and written to ' -ForegroundColor Green -NoNewline
Write-Host $outputDir'\vmInfo.xml' -ForegroundColor Cyan

#Shutdown VMs for migration
Write-Host
Write-Host 'Shutting down VMs for migration' -ForegroundColor Green
foreach ($vm in $vms)
{
    Stop-AzureVM -Name $vm.Name -ServiceName $vm.ServiceName -Force
    Start-Sleep -Seconds 5
}

#Wait for VMs to be stopped
Write-Host
Write-Host 'Waiting for VMs to stop' -ForegroundColor Green
$vmsStopped = $false
While (!($vmsStopped))
{
    Start-Sleep -Seconds 30
    $vmsStopped = $true
    foreach ($vm in $vms)
    {
        If ((Get-AzureVM -ServiceName $vm.ServiceName -Name $vm.Name).Status -eq 'StoppedDeallocated')
        {
            $vmsStopped = $vmsStopped -and $true
        }
        Else
        {
            $vmsStopped = $vmsStopped -and $false
        }
    }
}

#Delete VMs
Write-Host
Write-Host 'Deleting VMs' -ForegroundColor Green
foreach ($vm in $vms)
{
    Remove-AzureVM -Name $vm.Name -ServiceName $vm.ServiceName
}

Start-Sleep -Seconds 30

#Delete Cloud Services
Write-Host
Write-Host 'Deleting Cloud Services' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    If (Get-AzureService -ServiceName $vm.ServiceName -ErrorAction SilentlyContinue)
    {
        Remove-AzureService -ServiceName $vm.ServiceName -Force
    }
}

#Delete Affinity Groups
Write-Host
Write-Host 'Deleting Affinity Groups' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    If ($vm.ServiceAffinityGroup)
    {
        Remove-AzureAffinityGroup -Name $vm.ServiceAffinityGroup
    }
}

#Delete Azure Disks
Write-Host
Write-Host 'Deleting Azure Disks' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    Remove-AzureDisk -DiskName $vm.OSDisk.DiskName
    foreach ($d in $vm.DataDisks)
    {
        Remove-AzureDisk -DiskName $d.DiskName
    }
}

#Remove reserved IP addresses no longer in use
Write-Host
Write-Host 'Deleting Reserved IPs no longer in use' -ForegroundColor Green
Get-AzureReservedIP | where {$_.ServiceName -eq $null} | Remove-AzureReservedIP -Force

#Select destination subscription
Select-AzureSubscription -SubscriptionName $destinationSubscriptionName
Write-Host
Write-Host 'Selecting destination subscription ' -ForegroundColor Green -NoNewline
Write-Host $destinationSubscriptionName -ForegroundColor Cyan

#Create the destination storage account if it doesn't already exist
Write-Host
Write-Host 'Ensuring destination storage account exists - ' -ForegroundColor Green -NoNewline
Write-Host $destinationStorageAccount -ForegroundColor Cyan
If (!(Get-AzureStorageAccount -StorageAccountName $destinationStorageAccount -ErrorAction SilentlyContinue))
{
    New-AzureStorageAccount -StorageAccountName $destinationStorageAccount -Location $destinationStorageAccountLocation
}

#Obtain destination storage key and create destination storage context
$dstkey = (Get-AzureStorageKey -StorageAccountName $destinationStorageAccount).Primary
$dstContext = New-AzureStorageContext -StorageAccountName $destinationStorageAccount -StorageAccountKey $dstkey

#Create destination containers
Write-Host
Write-Host 'Creating containers in destination storage account' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    $dstcontainer = $vm.OSDisk.MediaLink.AbsoluteUri.Split('/')[3]
    If (!(Get-AzureStorageContainer -Context $dstContext | where {$_.Name -eq $dstcontainer}))
    {
        New-AzureStorageContainer -Context $dstContext -Name $dstcontainer
        Write-Host '   '$dstcontainer -ForegroundColor Cyan
    }
    foreach ($d in $vm.DataDisks)
    {
        $dstcontainer = $d.MediaLink.AbsoluteUri.Split('/')[3]
        If (!(Get-AzureStorageContainer -Context $dstContext | where {$_.Name -eq $dstcontainer}))
        {
            New-AzureStorageContainer -Context $dstContext -Name $dstcontainer
            Write-Host '   '$dstcontainer -ForegroundColor Cyan
        }
    }
}

#Copy VHD blobs
Write-Host
Write-Host 'Copying VHD BLOBs from source to destination' -ForegroundColor Green
Select-AzureSubscription -SubscriptionName $sourceSubscriptionName
$blobs = @()
ForEach ($vm in $vmInfo)
{
    #Obtain source storage key and create source storage context
    $sourceStorageAccount = $vm.OSDisk.MediaLink.AbsoluteUri.Split('/')[2].Split('.')[0]
    $srckey = (Get-AzureStorageKey -StorageAccountName $sourceStorageAccount).Primary
    $srcContext = New-AzureStorageContext -StorageAccountName $sourceStorageAccount -StorageAccountKey $srckey
    #Copy the OS disk BLOB
    $blobs += Start-AzureStorageBlobCopy -Srcuri $vm.OSDisk.MediaLink.AbsoluteUri -Context $srcContext -DestContainer vhds -DestBlob $vm.OSDisk.MediaLink.AbsoluteUri.Split('/')[4] -DestContext $dstContext

    #Copy each of the data disk BLOBs
    foreach ($d in $vm.DataDisks)
    {
        #Obtain source storage key and create source storage context
        $sourceStorageAccount = $d.MediaLink.AbsoluteUri.Split('/')[2].Split('.')[0]
        $srckey = (Get-AzureStorageKey -StorageAccountName $sourceStorageAccount).Primary
        $srcContext = New-AzureStorageContext -StorageAccountName $sourceStorageAccount -StorageAccountKey $srckey
               
        #Copy the data disk BLOB
        $blobs += Start-AzureStorageBlobCopy -Srcuri $d.MediaLink.AbsoluteUri -Context $srcContext -DestContainer vhds -DestBlob $d.MediaLink.AbsoluteUri.Split('/')[4] -DestContext $dstContext
    }
}

#Wait for VHD blob copy to complete
Write-Host
Write-Host 'Waiting for VHD BLOB copy to complete' -ForegroundColor Green
$copyComplete = $false
While (!($copyComplete))
{
    $copyComplete = $true
    ForEach ($blob in $blobs)
    {
        $status = $blob | Get-AzureStorageBlobCopyState
        If ($status.Status -ne 'Success')
        {
            $copyComplete = $copyComplete -and $false
        }
    }
    Start-Sleep -Seconds 60
}

#Create disks based on the VHD Blobs
Write-Host
Write-Host 'Creating disks from VHD BLOBs in desitnation' -ForegroundColor Green
Select-AzureSubscription -SubscriptionName $destinationSubscriptionName
ForEach ($vm in $vmInfo)
{
    $sourceStorageAccount = $vm.OSDisk.MediaLink.AbsoluteUri.Split('/')[2].Split('.')[0]
    Add-AzureDisk -DiskName $vm.OSDisk.DiskName -MediaLocation $vm.OSDisk.MediaLink.AbsoluteUri.Replace($sourceStorageAccount,$destinationStorageAccount) -OS $vm.OSDisk.OS
    foreach ($d in $vm.DataDisks)
    {
        $sourceStorageAccount = $d.MediaLink.AbsoluteUri.Split('/')[2].Split('.')[0]
        Add-AzureDisk -DiskName $d.DiskName -MediaLocation $d.MediaLink.AbsoluteUri.Replace($sourceStorageAccount,$destinationStorageAccount)
    }
}

#Create Affinity Groups
Write-Host
Write-Host 'Creating Affinity Groups' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    If ($vm.ServiceAffinityGroup)
    {
        New-AzureAffinityGroup -Name $vm.ServiceAffinityGroup -Location $vm.ServiceAffinityGroupLocation
    }
}

#Create Cloud Services
Write-Host
Write-Host 'Creating Cloud Services' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    If (!(Get-AzureService -ServiceName $vm.ServiceName -ErrorAction SilentlyContinue))
    {
        If ($vm.ServiceAffinityGroup)
        {
            New-AzureService -ServiceName $vm.ServiceName -AffinityGroup $vm.ServiceAffinityGroup
        }
        Else
        {
            New-AzureService -ServiceName $vm.ServiceName -Location $vm.ServiceLocation
        }
    }
}

#Create Reserved IP Addresses
Write-Host
Write-Host 'Creating Reserved IP Addresses' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    If ($vm.ReservedIPAddressName)
    {
        If (!(Get-AzureReservedIP -ReservedIPName $vm.ReservedIPAddressName -ErrorAction SilentlyContinue))
        {
            New-AzureReservedIP -ReservedIPName $vm.ReservedIPAddressName -Label $vm.ReservedIPAddressLabel -Location $vm.ReservedIPAddressLocation
        }
    }
}

#Create VMs
Write-Host
Write-Host 'Creating VMs' -ForegroundColor Green
foreach ($vm in $vmInfo)
{
    #Recreate internal load balancer configuration
    If ($vm.InternalLoadBalancers)
    {
        $ilbConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName $vm.InternalLoadBalancers.InternalLoadBalancerName -StaticVNetIPAddress $vm.InternalLoadBalancers.IPAddress -SubnetName $vm.InternalLoadBalancers.SubnetName
    }

    #Import VM configuration
    $vmconfig = Import-AzureVM -Path $vm.ExportPath

    #Create the VM with a Reserved IP if it had one and with a VNet if it was assigned to one
    If ($vm.ReservedIPAddressName)
    {
        If ($vm.VNet)
        {
            If ($vm.InternalLoadBalancers)
            {
                $vmconfig | New-AzureVM -ServiceName $vm.ServiceName -ReservedIPName $vm.ReservedIPAddressName -VNetName $vm.VNet -InternalLoadBalancerConfig $ilbConfig
            }
            Else
            {
                $vmconfig | New-AzureVM -ServiceName $vm.ServiceName -ReservedIPName $vm.ReservedIPAddressName -VNetName $vm.VNet
            }
        }
        Else
        {
            $vmconfig | New-AzureVM -ServiceName $vm.ServiceName -ReservedIPName $vm.ReservedIPAddressName
        }
    }
    Else
    {
        If ($vm.VNet)
        {
            If ($vm.InternalLoadBalancers)
            {
                $vmconfig | New-AzureVM -ServiceName $vm.ServiceName -VNetName $vm.VNet -InternalLoadBalancerConfig $ilbConfig
            }
            Else
            {
                $vmconfig | New-AzureVM -ServiceName $vm.ServiceName -VNetName $vm.VNet
            }
        }
        Else
        {
            $vmconfig | New-AzureVM -ServiceName $vm.ServiceName
        }
    }
}

#Wait for VMs to start
Write-Host
Write-Host 'Waiting for VMs to start' -ForegroundColor Green
$vmsStarted = $false
While (!($vmsStarted))
{
    Start-Sleep -Seconds 30
    $vmsStarted = $true
    foreach ($vm in $vmInfo)
    {
        If ((Get-AzureVM -ServiceName $vm.ServiceName -Name $vm.Name).Status -eq 'ReadyRole')
        {
            $vmsStarted = $vmsStarted -and $true
        }
        Else
        {
            $vmsStarted = $vmsStarted -and $false
        }
    }
}

#Finish
Write-Host
Write-Host "Migration complete!" -ForegroundColor Green
