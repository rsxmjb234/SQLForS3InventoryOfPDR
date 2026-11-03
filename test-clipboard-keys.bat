@echo off
REM ==========================================================================
REM  Diagnostic: test the credentials CURRENTLY ON THE CLIPBOARD without
REM  touching your ~/.aws files. Tells you immediately whether the keys you
REM  just copied are live or already expired, and prints the access key id so
REM  you can confirm the clipboard actually changed.
REM
REM  USE: copy the credentials block from the AWS portal, then run this.
REM ==========================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$c=Get-Clipboard -Raw;" ^
  "if([string]::IsNullOrWhiteSpace($c)){Write-Host 'Clipboard empty.' -ForegroundColor Red; exit 1};" ^
  "function Grab($names){foreach($n in $names){$m=[regex]::Match($c,'(?im)^(?:export\s+)?' + $n + '\s*=\s*\""?([^\""\r\n]+?)\""?\s*$'); if($m.Success){return $m.Groups[1].Value.Trim()}}; return ''};" ^
  "$ak=Grab(@('AWS_ACCESS_KEY_ID','aws_access_key_id'));" ^
  "$sk=Grab(@('AWS_SECRET_ACCESS_KEY','aws_secret_access_key'));" ^
  "$st=Grab(@('AWS_SESSION_TOKEN','aws_session_token'));" ^
  "if(-not $ak){Write-Host 'No access key found on clipboard.' -ForegroundColor Red; exit 1};" ^
  "Write-Host ('Clipboard access key id : ' + $ak) -ForegroundColor Cyan;" ^
  "Write-Host ('Local time now (UTC)     : ' + (Get-Date).ToUniversalTime().ToString('u')) -ForegroundColor Cyan;" ^
  "$env:AWS_ACCESS_KEY_ID=$ak; $env:AWS_SECRET_ACCESS_KEY=$sk; $env:AWS_SESSION_TOKEN=$st;" ^
  "$env:AWS_DEFAULT_REGION='us-east-1';" ^
  "Write-Host '----- testing these clipboard keys directly -----' -ForegroundColor Cyan;" ^
  "$id=(& cmd /c 'aws sts get-caller-identity 2>&1' | Out-String);" ^
  "if($id -match 'ExpiredToken' -or $id -match 'expired'){ Write-Host 'EXPIRED: the keys on your clipboard are already expired. Re-open the portal access-keys popup fresh and copy again.' -ForegroundColor Red }" ^
  "elseif($id -match '220065406231'){ Write-Host 'LIVE + CORRECT ACCOUNT. Now run updatekeys.bat to save them.' -ForegroundColor Green; Write-Host $id }" ^
  "elseif($id -match 'Account'){ Write-Host 'LIVE but WRONG account (not 220065406231). Pick the right portal tile.' -ForegroundColor Yellow; Write-Host $id }" ^
  "else{ Write-Host $id -ForegroundColor Red }"

echo.
pause
