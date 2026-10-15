param([Parameter(Mandatory=$true)][string]$Compiler,[string]$Version='0.5.0')
. "$PSScriptRoot\env.ps1"
if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid version'}
$compilerPath=(Resolve-Path -LiteralPath $Compiler).Path
if([System.IO.Path]::GetFileName($compilerPath) -ne 'ISCC.exe'){throw 'Specify an existing Inno Setup ISCC.exe'}
$bundle=Join-Path $ProjectRoot "artifacts\windows-$Version"
if(-not (Test-Path -LiteralPath "$bundle\haptics_lab.exe")){throw 'Package the verified portable build first'}
Invoke-Checked $compilerPath @('/Qp',"/DAppVersion=$Version","/DBundleRoot=$bundle","/DArtifactRoot=$ProjectRoot\artifacts","$ProjectRoot\packaging\windows.iss")
$file=Get-Item -LiteralPath "$ProjectRoot\artifacts\AIHapticsLab-$Version-windows-setup.exe"
[ordered]@{file=$file.Name;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;compiler=$compilerPath;installation_tested=$false} | ConvertTo-Json | Set-Content "$ProjectRoot\reports\installer.json" -Encoding utf8
