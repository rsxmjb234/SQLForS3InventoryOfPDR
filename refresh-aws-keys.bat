@echo off
REM ==========================================================================
REM  Refresh AWS temporary credentials from whatever is on the clipboard.
REM
REM  Accepts EITHER clipboard format from the AWS portal:
REM    - the "export AWS_ACCESS_KEY_ID=..." env-variable block, or
REM    - the "[profile ...] / aws_access_key_id=..." INI block,
REM  and writes BOM-less UTF-8 to ~/.aws/credentials and ~/.aws/config.
REM
REM  Silent on success. On any failure it prints the reason and pauses.
REM
REM  HOW TO USE: copy the credentials block from the AWS access portal, then
REM  double-click this file (or run it from a terminal).
REM ==========================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$profile='220065406231_pdr-nyec-program-team-PROD';" ^
  "$awsdir=Join-Path $env:USERPROFILE '.aws';" ^
  "if(-not(Test-Path $awsdir)){New-Item -ItemType Directory -Path $awsdir | Out-Null};" ^
  "$cred=Join-Path $awsdir 'credentials';" ^
  "$cfg=Join-Path $awsdir 'config';" ^
  "$c=Get-Clipboard -Raw;" ^
  "if([string]::IsNullOrWhiteSpace($c)){Write-Host 'Clipboard is empty. Copy the credentials block first.' -ForegroundColor Red; exit 1};" ^
  "function Grab($names){foreach($n in $names){$m=[regex]::Match($c,'(?im)^(?:export\s+)?' + $n + '\s*=\s*\""?([^\""\r\n]+?)\""?\s*$'); if($m.Success){return $m.Groups[1].Value.Trim()}}; return ''};" ^
  "$ak=Grab(@('AWS_ACCESS_KEY_ID','aws_access_key_id'));" ^
  "$sk=Grab(@('AWS_SECRET_ACCESS_KEY','aws_secret_access_key'));" ^
  "$st=Grab(@('AWS_SESSION_TOKEN','aws_session_token'));" ^
  "if(-not $ak -or -not $sk -or -not $st){Write-Host 'Could not find all three keys on the clipboard (access key, secret, session token). Nothing changed.' -ForegroundColor Red; exit 1};" ^
  "if(Test-Path $cred){Copy-Item $cred ($cred+'.bak') -Force};" ^
  "if(Test-Path $cfg){Copy-Item $cfg ($cfg+'.bak') -Force};" ^
  "$nl=[char]10;" ^
  "$credText='['+$profile+']'+$nl+'aws_access_key_id = '+$ak+$nl+'aws_secret_access_key = '+$sk+$nl+'aws_session_token = '+$st+$nl;" ^
  "$cfgText='[profile '+$profile+']'+$nl+'region = us-east-1'+$nl+'output = json'+$nl;" ^
  "$enc=New-Object System.Text.UTF8Encoding($false);" ^
  "[System.IO.File]::WriteAllText($cred,$credText,$enc);" ^
  "[System.IO.File]::WriteAllText($cfg,$cfgText,$enc);" ^
  "$ErrorActionPreference='Continue';" ^
  "$id=(& cmd /c 'aws sts get-caller-identity --profile 220065406231_pdr-nyec-program-team-PROD 2>&1' | Out-String);" ^
  "if($id -match 'ExpiredToken' -or $id -match 'expired'){ Write-Host 'FAIL: the pasted token is already EXPIRED. Copy fresh keys from the portal and run this again.' -ForegroundColor Red; exit 1 }" ^
  "elseif($id -notmatch '220065406231'){ if($id -match 'Account'){ Write-Host 'WARNING: logged in, but NOT to account 220065406231 - check you used the right portal tile.' -ForegroundColor Yellow } else { Write-Host 'Could not verify login:' -ForegroundColor Red }; Write-Host $id; exit 1 }"

if errorlevel 1 pause
