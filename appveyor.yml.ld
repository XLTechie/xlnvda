os: Visual Studio 2019
version: "{branch}-{build}"
clone_folder: c:\projects\nvda

branches:
 except:
  - master

environment:
 PY_PYTHON: 3.7-32
 symstore: C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\symstore.exe

init:
 - ps: |
     # iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/appveyor/ci/master/scripts/enable-rdp.ps1'))
     $pythonVersion = (py --version)
     Add-AppveyorMessage "#ld: Python version: " $pythonVersion
     echo $pythonVersion
     if ($env:APPVEYOR_REPO_TAG_NAME -and $env:APPVEYOR_REPO_TAG_NAME.StartsWith("release-")) {
      Add-AppveyorMessage "#ld: in if 1"
      # Strip "release-" prefix.
      $version = $env:APPVEYOR_REPO_TAG_NAME.Substring(8)
      Set-AppveyorBuildVariable "release" "1"
     } else {
      Add-AppveyorMessage "#ld: In else 1"
      $versionType = "stable"
     }
     Add-AppveyorMessage "#ld: Out of if 1"
     $version = "$env:APPVEYOR_REPO_BRANCH-$env:APPVEYOR_BUILD_NUMBER," + $env:APPVEYOR_REPO_COMMIT.Substring(0, 8)
     # The version is unique even for rebuilds, so we can use it for the AppVeyor version.
     Update-AppveyorBuild -Version $version
     Set-AppveyorBuildVariable "version" $version
     if ($versionType) {
      Add-AppveyorMessage "#ld: In if 3, versionType: " $versionType
      Set-AppveyorBuildVariable "versionType" $versionType
     }
     Add-AppveyorMessage "#ld: Out of if 3"

clone_depth: 1

install:
 - git submodule update --init

build_script:
 - ps: |
     Add-AppveyorMessage "#ld: In build script."
     $sconsOutTargets = "launcher developerGuide  changes userGuide client"
     $sconsOutTargets += " appx"
     Add-AppveyorMessage "#ld: scons out targets: " $sconsOutTargets
     $sconsArgs = "version=$env:version"
     if ($env:release) {
      Add-AppveyorMessage "#ld: In if 5."
      $sconsArgs += " release=1"
     }
     if ($env:versionType) {
      Add-AppveyorMessage "#ld: In if 6."
      $sconsArgs += " updateVersionType=$env:versionType"
     }
     Add-AppveyorMessage "#ld: Out of ifs 5 and 6."
     $sconsArgs += ' publisher="Open Source Systems, Ltd."'
     $sconsArgs += " version_build=$env:APPVEYOR_BUILD_NUMBER"
     # We use cmd to run scons because PowerShell throws exceptions if warnings get dumped to stderr.
     # It's possible to work around this, but the workarounds have annoying side effects.
     Set-AppveyorBuildVariable "sconsOutTargets" $sconsOutTargets
     Set-AppveyorBuildVariable "sconsArgs" $sconsArgs
     Add-AppveyorMessage "#ld: scons args: " $sconsArgs

 - 'echo scons args: %sconsArgs%'
 - scons source %sconsArgs%
 - if ERRORLEVEL 1 exit %ERRORLEVEL%
 # We don't need launcher to run checkPot, so run the checkPot before launcher.
 - ps: |
     cmd.exe /c "scons checkPot $sconsArgs"
     if($LastExitCode -ne 0) {
      $errorCode=$LastExitCode
      Add-AppveyorMessage "#ld: In if 1."
      Add-AppveyorMessage "Translation comments missing or unexpectedly included."
     }
     if ($errorCode -ne 0) { $host.SetShouldExit($errorCode) }
 # The pot gets built by tests, but we don't actually need it as a build artifact.
 - 'echo scons output targets: %sconsOutTargets%'
 - scons %sconsOutTargets% %sconsArgs%
 - if ERRORLEVEL 1 exit %ERRORLEVEL%
 # Build symbol store.
 - ps: |
     Add-AppveyorMessage "#ld: In the symbols section."
     foreach ($syms in
      # We don't just include source\*.dll because that would include system dlls.
      "source\liblouis.dll", "source\*.pdb",
      "source\lib\*.dll", "source\lib\*.pdb",
      # We include source\lib64\*.exe to cover nvdaHelperRemoteLoader.
      "source\lib64\*.dll", "source\lib64\*.exe", "source\lib64\*.pdb",
      "source\synthDrivers\*.dll", "source\synthDrivers\*.pdb"
     ) {
      & $env:symstore add /s symbols /compress -:NOREFS /t NVDA /f $syms
     }
 - cd symbols
 - 7z a -tzip -r ..\output\symbols.zip *.dl_ *.ex_ *.pd_
 - if ERRORLEVEL 1 exit %ERRORLEVEL%
 - cd ..

before_test:
 - mkdir testOutput
 - mkdir testOutput\unit
 - mkdir testOutput\system
 - mkdir testOutput\lint
 - ps: |
     $errorCode=0
     Add-AppveyorMessage "#ld: In output."
     $nvdaLauncherFile=".\output\nvda"
     if(!$env:release) {
      Add-AppveyorMessage "#ld: In if 7."
      $nvdaLauncherFile+="_snapshot"
     }
     Add-AppveyorMessage "#ld: Out of if 7."
     $nvdaLauncherFile+="_${env:version}.exe"
     Set-AppveyorBuildVariable "nvdaLauncherFile" $nvdaLauncherFile
     echo NVDALauncherFile: $NVDALauncherFile
     $outputDir=$(resolve-path .\testOutput)
     $installerLogFilePath="$outputDir\nvda_install.log"
     $installerProcess=start-process -FilePath "$nvdaLauncherFile" -ArgumentList "--install-silent --debug-logging --log-file $installerLogFilePath" -passthru
     try {
      $installerProcess | wait-process -Timeout 180
      $errorCode=$installerProcess.ExitCode
     } catch {
      echo "NVDA installer process timed out"
      $errorCode=1
      Add-AppveyorMessage "Unable to install NVDA prior to tests."
     }
     Push-AppveyorArtifact $installerLogFilePath
     $crashDump = "$outputDir\nvda_crash.dmp"
     if (Test-Path -Path $crashDump){
      Push-AppveyorArtifact $crashDump -FileName "nvda_install_crash.dmp"
      Add-AppveyorMessage "Install process crashed"
      $errorCode=1
     }
     if($errorCode -ne 0) { $host.SetShouldExit($errorCode) }

test_script:
# Unit Tests (Python)
 - ps: |
     Add-AppveyorMessage "#ld: In test script."
     $errorCode=0
     $outDir = (Resolve-Path .\testOutput\unit\)
     $unitTestsXml = "$outDir\unitTests.xml"
     .\rununittests.bat --with-xunit --xunit-file="$unitTestsXml"
     if($LastExitCode -ne 0) {
      $errorCode=$LastExitCode
      Add-AppveyorMessage "Unit test failure"
     }
     Push-AppveyorArtifact $unitTestsXml
     $wc = New-Object 'System.Net.WebClient'
     $wc.UploadFile("https://ci.appveyor.com/api/testresults/junit/$($env:APPVEYOR_JOB_ID)", $unitTestsXml)
     if($errorCode -ne 0) { $host.SetShouldExit($errorCode) }

# System tests
 - ps: |
     Add-AppveyorMessage "#ld: In system tests."
     $testOutput = (Resolve-Path .\testOutput\)
     $systemTestOutput = (Resolve-Path "$testOutput\system")
     .\runsystemtests.bat --variable whichNVDA:installed --variable installDir:"${env:nvdaLauncherFile}" --include installer
     if($LastExitCode -ne 0) {
      $errorCode=$LastExitCode
      Add-AppveyorMessage "System test failure"
     }
     Compress-Archive -Path "$systemTestOutput\*" -DestinationPath "$testOutput\systemTestResult.zip"
     Push-AppveyorArtifact "$testOutput\systemTestResult.zip"
     $wc = New-Object 'System.Net.WebClient'
     $wc.UploadFile("https://ci.appveyor.com/api/testresults/junit/$($env:APPVEYOR_JOB_ID)", (Resolve-Path "$systemTestOutput\systemTests.xml"))
     if($errorCode -ne 0) { $host.SetShouldExit($errorCode) }

# Artifacts are required by deploy code,
artifacts:
  - path: output\*
  - path: output\*\*

# Still upload artifacts on failure, they are useful for testing PR builds despite the build perhaps
# failing for a minor reason (eg linting)
on_failure:
#  `- path` is not allowed in `on_failure` use powerShell instead
 - ps: |
    Add-AppveyorMessage "#ld: In on failure."
    # Upload artifacts, preserving directory structure.
    $uploadFromFolder = "output\"
    if( Test-Path $uploadFromFolder ){
      $root = Resolve-Path .\
      $output = Resolve-Path $uploadFromFolder
      $paths = [IO.Directory]::GetFiles($output.Path, '*.*', 'AllDirectories')
      $paths | % {
        Push-AppveyorArtifact $_ -FileName $_.Substring($root.Path.Length + 1)
      }
    }

# The server side deploy code ('nvdaAppveyorHook') relies on artifacts, they must be uploaded first.
# For ordering of appveyor yml phases, see: https://www.appveyor.com/docs/build-configuration/#build-pipeline
deploy_script:
 - ps: |
     Add-AppveyorMessage "#ld: In deploy."
     if (!$env:APPVEYOR_PULL_REQUEST_NUMBER -and $env:versionType) {
      # Not a try build.
      # Notify our server.
      $exe = Get-ChildItem -Name output\*.exe
      $hash = (Get-FileHash "output\$exe" -Algorithm SHA1).Hash.ToLower()
      $apiVersion = (py -c "import sys; sys.path.append('source'); from addonAPIVersion import CURRENT; print('{}.{}.{}'.format(*CURRENT))")
      echo apiversion: $apiVersion
      $apiCompatTo = (py -c "import sys; sys.path.append('source'); from addonAPIVersion import BACK_COMPAT_TO; print('{}.{}.{}'.format(*BACK_COMPAT_TO))")
      echo apiBackCompatTo: $apiCompatTo
      $data = @{
       jobId=$env:APPVEYOR_JOB_ID;
       commit=$env:APPVEYOR_REPO_COMMIT;
       version=$env:version; versionType=$env:versionType;
       apiVersion=$apiVersion; apiCompatTo=$apiCompatTo;
       avVersion=$env:APPVEYOR_BUILD_VERSION;
       branch=$env:APPVEYOR_REPO_BRANCH;
       exe=$exe; hash=$hash;
       artifacts=$artifacts
      }
      ConvertTo-Json -InputObject $data -Compress | Out-File -FilePath deploy.json
      Push-AppveyorArtifact deploy.json
      # Execute the deploy script on the NV Access server via ssh.
      # Warning: if the server address is changed, 
      # The new address must be also included in appveyor\ssh_known_hosts in this repo
      # Otherwise ssh will freeze on input!
      #cat deploy.json | ssh nvaccess@deploy.nvaccess.org nvdaAppveyorHook

      # Upload symbols to Mozilla.
      #py -m pip install --no-warn-script-location requests
      #py appveyor\mozillaSyms.py
      #if($LastExitCode -ne 0) {
        #$errorCode=$LastExitCode
        #echo "Unable to upload symbols to Mozilla"
        #Add-AppveyorMessage "Unable to upload symbols to Mozilla"
      #}
     }

on_finish:
  # add a message to point to the NVDA build, to make testing PR's easier.
  - ps: |
      Add-AppveyorMessage "#ld: In on finish."
      # Save an exact list of the actual Python packages and their versions that got installed, to aide in reproducing a build
      .\venvUtils\exportPackageList.bat installed_python_packages.txt
      Push-AppveyorArtifact installed_python_packages.txt
      $appVeyorUrl = "https://ci.appveyor.com"
      $exe = Get-ChildItem -Name output\*.exe
      if($?){
        $exeUrl="$appVeyorUrl/api/buildjobs/$env:APPVEYOR_JOB_ID/artifacts/output/$exe"
        Add-AppveyorMessage "[Build (for testing PR)]($exeUrl)"
      }

notifications:
  - provider: Email
    to:
      - luke@newanswertech.com
    subject: 'Build {{status}}'
    message: "{{branch}}, {{messages}}, {{message}}, {{commitId}}"
    on_build_status_changed: true
