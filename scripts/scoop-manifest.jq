{
  version: $version,
  description: "Native voice dictation powered by a shared Rust engine",
  homepage: "https://github.com/kodmial/nanodictate",
  architecture: {"64bit": {url: $url, hash: $hash}},
  shortcuts: [["NanoDictate.App.exe", "NanoDictate"]],
  pre_install: [
    "if ($global) { throw 'NanoDictate installs per user only; rerun without --global.' }",
    "if ($cmd -eq 'update') { $root = Join-Path $scoopdir 'apps\\nanodictate\\'; Get-Process -Name 'NanoDictate.App' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction Stop }"
  ],
  post_install: [
    "$exe = Join-Path $dir 'NanoDictate.App.exe'; if (!(Test-Path $exe)) { throw 'Installed NanoDictate executable missing' }",
    "$key = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'; New-Item -Path $key -Force | Out-Null; Set-ItemProperty -Path $key -Name 'NanoDictate' -Value ('\"' + $exe + '\" --background')",
    "if ($cmd -eq 'install') { Start-Process -FilePath $exe } elseif ($cmd -eq 'update') { Start-Process -FilePath $exe -ArgumentList '--background' }"
  ],
  pre_uninstall: [
    "if ($cmd -eq 'uninstall') { $key = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'; $value = (Get-ItemProperty -Path $key -Name 'NanoDictate' -ErrorAction SilentlyContinue).NanoDictate; if ($value -and $value.Contains($scoopdir)) { Remove-ItemProperty -Path $key -Name 'NanoDictate' -ErrorAction SilentlyContinue }; $root = Join-Path $scoopdir 'apps\\nanodictate\\'; Get-Process -Name 'NanoDictate.App' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction Stop }"
  ]
}
