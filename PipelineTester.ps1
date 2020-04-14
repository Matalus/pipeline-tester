#Script for testing Pipeline Permissions

param(
   [Parameter(Mandatory = $true,ValueFromPipelineByPropertyName, Position=0)]
   [ValidatePattern('.*\.yml')]
   [string]$file,

   [Parameter(Mandatory = $false)]
   [switch]$BuildOnly,

   [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName)]

   [AllowEmptyString()]
   [switch]$AppOnly
)

#define rundir
$RunDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

#import Powershell-Yaml

if (!(Get-Module powershell-yaml)) {
   Install-Module powershell-yaml -Force -Verbose
}


Write-Host -ForegroundColor Yellow "Loading Config: $file"
$Config = (Get-Content $file) -join "`n" | ConvertFrom-Yaml


# Generate credential object if doesn't exist
if(!$Cred){
   $Cred = Get-Credential
}

Function Get-IPByHost ($HostName){
   Try{
      $IP = [System.Net.Dns]::GetHostAddresses($HostName)
   }Catch{
      return $null
   }
   return $IP.IPAddressToString
}

#Test Socket Function
Function Test-Port($SourceHost, $TargetHost, $Port, $Cred){
   #Remote Params
   $InvokeParams = @{
      ComputerName = $SourceHost
      ArgumentList = $TargetHost,$Port
      credential = $Cred
      ErrorAction = "SilentlyContinue"
      ScriptBlock = {
         #Write-Host "Connecting to $($args[0]) : $($args[1])" # uncomment to debug
         Try{
            $TCP = New-Object System.Net.Sockets.TcpClient
            $Connect = $TCP.BeginConnect($args[0],$args[1],$null,$null)
            $Wait = $Connect.AsyncWaitHandle.WaitOne(500,$False) # add Async Timeout
         }Catch{}
         if($Wait){
            $null = $Conn.EndConnect($Connect) # close connection
            Return $True
         }else{
            Return $False
         }
      }
   }
   Invoke-Command @InvokeParams   
}

#Create fail array
$AccessFails = @()

if(!$PSBoundParameters.ContainsKey("AppOnly")){

Write-Host -ForegroundColor Yellow "Testing Release Server Access..."

"Found $($Config.Release.Servers.Count) Release Servers in config"

   # loop though release servers
   ForEach($Server in $Config.Release.Servers){
      "`nTesting : $($Server)"
      ForEach($Env in $Config.Environments){
         Write-Host -ForegroundColor Magenta "$($Env.Name):"
         ForEach($ReleaseServer in $Env.Servers){
            ForEach($Port in $Config.Release.Ports){
               Write-Host -NoNewline "   $Server --> $($ReleaseServer) : ".PadRight(80," ")
               Write-Host -NoNewline -ForegroundColor Cyan "$($Port)".PadRight(5," ")
               $TestParams = @{
                  SourceHost = $Server
                  TargetHost = $ReleaseServer
                  Port = $Port
                  Cred = $Cred
               }
               $Test = Test-Port @TestParams
               if($Test){
                  Write-Host -ForegroundColor Green " OK"
               }else{
                  Write-Host -ForegroundColor Red " Fail"
                  $AccessFails += [PSCustomObject]@{
                     Source_Server = $Server
                     Source_IP = (Get-IPByHost $Server)
                     Target_Server = $ReleaseServer
                     Target_IP = (Get-IPByHost $ReleaseServer)
                     Port = $Port
                  }
               }
            }
         } 
      }
   }
}


#Loop through ancillary ports
if(!$PSBoundParameters.ContainsKey("BuildOnly")){
   Write-Host -ForegroundColor Yellow "`nTesting Application Server Access..."

   ForEach($Env in $Config.Environments){
      Write-Host -ForegroundColor Magenta "$($Env.Name):"
      ForEach($Server in $Env.Servers){
         ForEach($AppServer in $Env.Ancillary){
            ForEach($Port in $AppServer.Ports){
               Write-Host -NoNewline "   $Server --> $($AppServer.Name) : ".PadRight(80," ")
               Write-Host -NoNewline -ForegroundColor Cyan "$($Port)".PadRight(5," ")
               $TestParams = @{
                  SourceHost = $Server
                  TargetHost = $AppServer.Name
                  Port = $Port
                  Cred = $Cred
               }
               $Test = Test-Port @TestParams
               if($Test){
                  Write-Host -ForegroundColor Green " OK"
               }else{
                  Write-Host -ForegroundColor Red " Fail"
                  $AccessFails += [PSCustomObject]@{
                     Source_Server = $Server
                     Source_IP = (Get-IPByHost $Server)
                     Target_Server = $AppServer.Name
                     Target_IP = (Get-IPByHost $AppServer.Name)
                     Port = $Port
                  }
               }
            }
         }    
      }
   }
}

Write-Host -ForegroundColor Yellow "Failed: " -NoNewline
Write-Host -ForegroundColor Red $AccessFails.Count

$AccessFails | Select-Object * | Export-Csv -Path .\Firewall_Request.csv -Force -NoTypeInformation

