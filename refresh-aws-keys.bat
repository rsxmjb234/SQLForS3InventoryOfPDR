@echo off
REM ==========================================================================
REM  Refresh AWS temporary credentials from whatever is on the clipboard.
REM
REM  Fixes the two problems that kept corrupting ~/.aws/config:
REM    1. Writes BOM-less UTF-8 (the old "-Encoding UTF8" added a BOM that
REM       botocore could not parse).
REM    2. Accepts EITHER clipboard format from the AWS portal:
REM         - the "export AWS_ACCESS_KEY_ID=..." env-variable block, or
REM         - the "[profile ...] / aws_access_key_id=..." INI block,
REM       and normalizes it into the credentials file in the correct form.
REM
REM  It writes keys to ~/.aws/credentials (not config), leaves config as a
REM  clean header + region, then prints the credentials file and runs a
REM  validity check (sts get-caller-identity).
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
  "Write-Host 'AWS credentials refreshed.' -ForegroundColor Green;" ^
  "Write-Host '';" ^
  "Write-Host '----- ~/.aws/credentials (session token truncated) -----' -ForegroundColor Cyan;" ^
  "Get-Content $cred | ForEach-Object { if($_ -match '^aws_session_token'){ 'aws_session_token = ' + $st.Substring(0,[Math]::Min(24,$st.Length)) + '...(' + $st.Length + ' chars)' } elseif($_ -match '^aws_secret_access_key'){ 'aws_secret_access_key = ****(hidden)' } else { $_ } };" ^
  "Write-Host '';" ^
  "Write-Host '----- validity check (aws sts get-caller-identity) -----' -ForegroundColor Cyan;" ^
  "$ErrorActionPreference='Continue';" ^
  "$id=(& cmd /c 'aws sts get-caller-identity --profile 220065406231_pdr-nyec-program-team-PROD 2>&1' | Out-String);" ^
  "if($id -match 'ExpiredToken' -or $id -match 'expired'){ Write-Host 'FAIL: the pasted token is already EXPIRED. Copy fresh keys from the portal and run this again.' -ForegroundColor Red }" ^
  "elseif($id -match '220065406231'){ Write-Host 'OK: logged in to account 220065406231.' -ForegroundColor Green; Write-Host $id }" ^
  "elseif($id -match 'Account'){ Write-Host 'WARNING: logged in, but NOT to account 220065406231 - check you used the right portal tile.' -ForegroundColor Yellow; Write-Host $id }" ^
  "else{ Write-Host 'Could not verify login:' -ForegroundColor Red; Write-Host $id }"

echo.
echo ============================================================
echo  FULL ~/.aws/credentials  (contains real secrets - do not share)
echo ============================================================
type "%USERPROFILE%\.aws\credentials"
echo.
echo ============================================================
echo  FULL ~/.aws/config
echo ============================================================
type "%USERPROFILE%\.aws\config"
echo.
pause
