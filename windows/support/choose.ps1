#Requires -Version 5.1
# The two choice screens of the Windows installer (dot-sourced after lib.ps1):
#   1. what Claude is for: office work, programming, or both
#   2. what to install for that: modules, OCR languages, programming languages
# Show-Choice returns @{ Purpose; Office; Dev; Ocr } or $null when cancelled.
# Every text comes from i18n; labels grow with their text, so longer
# translations wrap instead of being cut.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace ClaudeIdeBox -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction SilentlyContinue

function Get-OcrLanguageName([string]$culture, [string]$code) {
  try {
    $ci = [Globalization.CultureInfo]::GetCultureInfo($culture)
    $n = $ci.NativeName -replace '\s*\(.*\)$', ''
    if ($culture -like 'zh-*') { $n = $ci.NativeName }
    return ($ci.TextInfo.ToUpper($n.Substring(0, 1)) + $n.Substring(1)) + "  ($code)"
  } catch {
    return $code
  }
}

# Tesseract code for the Windows UI language, if the catalog has one.
function Get-DefaultOcrLanguages($catalog) {
  $ui = Get-UICulture
  $codes = @('eng')
  foreach ($l in $catalog.OcrLanguages) {
    $c = [Globalization.CultureInfo]::GetCultureInfo($l.Culture)
    $match = $false
    if ($l.Culture -like 'zh-*') {
      $match = ($ui.Name -in @('zh-CN', 'zh-SG') -and $l.Culture -eq 'zh-Hans') -or
               ($ui.Name -in @('zh-TW', 'zh-HK', 'zh-MO') -and $l.Culture -eq 'zh-Hant')
    } else {
      $match = $c.TwoLetterISOLanguageName -eq $ui.TwoLetterISOLanguageName
    }
    if ($match -and $codes -notcontains $l.Code) { $codes += $l.Code }
  }
  return , $codes
}

function Get-PresetDomains([string]$srcRoot, [string]$preset) {
  $f = Join-Path $srcRoot "proxy\presets\$preset.txt"
  if (-not (Test-Path $f)) { return '' }
  return ((Get-Content $f | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
      ForEach-Object { $_.Trim() }) -join ', ')
}

function Format-Size([int]$mb) {
  $gb = [math]::Round($mb / 1024, 1)
  return $gb.ToString('0.0', (Get-Culture))
}

function Show-Choice($catalog, [string]$srcRoot, $current) {
  try { [void][ClaudeIdeBox.Dpi]::SetProcessDPIAware() } catch { }
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $wrap = 600
  $font = New-Object Drawing.Font('Segoe UI', 10)
  $bold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
  $title = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
  $muted = [Drawing.Color]::FromArgb(90, 90, 90)

  function New-Label([string]$text, $f, [int]$indent, [int]$top) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.MaximumSize = New-Object Drawing.Size(($wrap - $indent), 0)
    $l.Margin = New-Object Windows.Forms.Padding($indent, $top, 0, 0)
    if ($f) { $l.Font = $f } else { $l.Font = $font }
    return $l
  }

  # Starting point: the previous choice, else office work with everything
  # for documents and OCR in English plus the Windows language.
  $purpose = 'office'
  $officeSel = @($catalog.Office | ForEach-Object { $_.Id })
  $devSel = @()
  $ocrSel = Get-DefaultOcrLanguages $catalog
  if ($current -and $current.Purpose) {
    $purpose = $current.Purpose
    $officeSel = @($current.Office)
    $devSel = @($current.Dev)
    if ($current.Ocr) { $ocrSel = @($current.Ocr) }
  }

  $form = New-Object Windows.Forms.Form
  $form.SuspendLayout()
  $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
  $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
  $form.Text = M 'App_Name'
  $form.Font = $font
  $form.ClientSize = New-Object Drawing.Size(680, 600)
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.BackColor = [Drawing.Color]::White
  $form.Topmost = $true

  $root = New-Object Windows.Forms.TableLayoutPanel
  $root.Dock = 'Fill'
  $root.RowCount = 3
  $root.ColumnCount = 1
  $root.Padding = New-Object Windows.Forms.Padding(24, 18, 24, 12)
  [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
  [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
  [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
  $form.Controls.Add($root)

  $head = New-Object Windows.Forms.FlowLayoutPanel
  $head.FlowDirection = 'TopDown'
  $head.WrapContents = $false
  $head.AutoSize = $true
  $headTitle = New-Label '' $title 0 0
  $headSub = New-Label '' $null 0 6
  $headSub.ForeColor = $muted
  $head.Controls.AddRange(@($headTitle, $headSub))
  $root.Controls.Add($head, 0, 0)

  $body = New-Object Windows.Forms.Panel
  $body.Dock = 'Fill'
  $root.Controls.Add($body, 0, 1)

  function New-Page {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = 'TopDown'
    $p.WrapContents = $false
    $p.AutoScroll = $true
    $p.Dock = 'Fill'
    $p.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    return $p
  }

  # Screen 1: purpose ---------------------------------------------------------
  $page1 = New-Page
  $radios = @{}
  foreach ($id in @('office', 'dev', 'both')) {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = M "Purpose_$id"
    $r.Font = $bold
    $r.AutoSize = $true
    $r.Margin = New-Object Windows.Forms.Padding(0, 14, 0, 0)
    $r.Tag = $id
    $r.Checked = ($id -eq $purpose)
    $radios[$id] = $r
    $page1.Controls.Add($r)
    $page1.Controls.Add((New-Label (M "Purpose_${id}_Desc") $null 22 2))
  }
  $page1.Controls.Add((New-Label (M 'Choose_ChangeLater') $null 0 24))
  $page1.Controls[$page1.Controls.Count - 1].ForeColor = $muted

  # Screen 2: what to install -------------------------------------------------
  $page2 = New-Page
  $page2.Visible = $false
  $checks = @{}

  $officeHead = New-Label (M 'Group_office') $bold 0 4
  $page2.Controls.Add($officeHead)
  $officeCtl = @($officeHead)
  foreach ($m in $catalog.Office) {
    $c = New-Object Windows.Forms.CheckBox
    $txt = M "Module_$($m.Id)"
    if ($m.SizeMB -gt 0) { $txt += '   ' + (M 'Size_Approx' (Format-Size $m.SizeMB)) }
    $c.Text = $txt
    $c.AutoSize = $true
    $c.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $c.Checked = $officeSel -contains $m.Id
    $checks[$m.Id] = $c
    $d = New-Label (M "Module_$($m.Id)_Desc") $null 20 0
    $d.ForeColor = $muted
    $page2.Controls.AddRange(@($c, $d))
    $officeCtl += @($c, $d)
  }
  $ocrLabel = New-Label (M 'Ocr_Languages') $null 20 8
  $ocrList = New-Object Windows.Forms.CheckedListBox
  $ocrList.CheckOnClick = $true
  $ocrList.Width = 320
  $ocrList.Height = 130
  $ocrList.Margin = New-Object Windows.Forms.Padding(20, 4, 0, 0)
  $ocrCodes = @()
  # Selected languages first, then the rest in catalog order.
  $ordered = @($catalog.OcrLanguages | Where-Object { $ocrSel -contains $_.Code }) +
             @($catalog.OcrLanguages | Where-Object { $ocrSel -notcontains $_.Code })
  foreach ($l in $ordered) {
    $i = $ocrList.Items.Add((Get-OcrLanguageName $l.Culture $l.Code))
    $ocrList.SetItemChecked($i, ($ocrSel -contains $l.Code))
    $ocrCodes += $l.Code
  }
  $page2.Controls.AddRange(@($ocrLabel, $ocrList))
  $officeCtl += @($ocrLabel, $ocrList)

  $devHead = New-Label (M 'Group_dev') $bold 0 22
  $devNote = New-Label (M 'Dev_Note') $null 0 4
  $devNote.ForeColor = $muted
  $page2.Controls.AddRange(@($devHead, $devNote))
  $devCtl = @($devHead, $devNote)
  foreach ($m in $catalog.Dev) {
    $c = New-Object Windows.Forms.CheckBox
    $txt = M "Module_$($m.Id)"
    if ($m.SizeMB -gt 0) { $txt += '   ' + (M 'Size_Approx' (Format-Size $m.SizeMB)) }
    $c.Text = $txt
    $c.AutoSize = $true
    $c.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $c.Checked = $devSel -contains $m.Id
    $checks[$m.Id] = $c
    $desc = M "Module_$($m.Id)_Desc"
    $domains = Get-PresetDomains $srcRoot $m.Preset
    if ($domains) { $desc += ' ' + (M 'Dev_Opens' $domains) }
    $d = New-Label $desc $null 20 0
    $d.ForeColor = $muted
    $page2.Controls.AddRange(@($c, $d))
    $devCtl += @($c, $d)
  }
  $sizeLabel = New-Label '' $bold 0 22
  $later = New-Label (M 'Choose_ChangeLater') $null 0 6
  $later.ForeColor = $muted
  $page2.Controls.AddRange(@($sizeLabel, $later))

  $body.Controls.Add($page2)
  $body.Controls.Add($page1)

  # Buttons ---------------------------------------------------------------------
  $buttons = New-Object Windows.Forms.FlowLayoutPanel
  $buttons.FlowDirection = 'RightToLeft'
  $buttons.AutoSize = $true
  $buttons.Dock = 'Fill'
  $next = New-Object Windows.Forms.Button
  $next.AutoSize = $true
  $next.MinimumSize = New-Object Drawing.Size(110, 32)
  $back = New-Object Windows.Forms.Button
  $back.Text = M 'Button_Back'
  $back.AutoSize = $true
  $back.MinimumSize = New-Object Drawing.Size(110, 32)
  $cancel = New-Object Windows.Forms.Button
  $cancel.Text = M 'Button_Cancel'
  $cancel.AutoSize = $true
  $cancel.MinimumSize = New-Object Drawing.Size(110, 32)
  $cancel.DialogResult = 'Cancel'
  $buttons.Controls.AddRange(@($next, $back, $cancel))
  $root.Controls.Add($buttons, 0, 2)
  $form.CancelButton = $cancel
  $form.AcceptButton = $next

  $selPurpose = { foreach ($k in $radios.Keys) { if ($radios[$k].Checked) { return $k } }; return 'office' }

  $updateSize = {
    $p = & $selPurpose
    $mb = [int]$catalog.BaseSizeMB
    $unknown = $false
    if ($p -ne 'dev') {
      foreach ($m in $catalog.Office) {
        if ($checks[$m.Id].Checked) {
          if ($m.SizeMB -gt 0) { $mb += $m.SizeMB } else { $unknown = $true }
          if ($m.Id -eq 'ocr' -and $m.PerLanguageMB) { $mb += $m.PerLanguageMB * $ocrList.CheckedItems.Count }
        }
      }
    }
    if ($p -ne 'office') {
      foreach ($m in $catalog.Dev) {
        if ($checks[$m.Id].Checked) { if ($m.SizeMB -gt 0) { $mb += $m.SizeMB } else { $unknown = $true } }
      }
    }
    $t = M 'Size_Total' (Format-Size $mb)
    if ($unknown) { $t += ' ' + (M 'Size_PlusUnknown') }
    $sizeLabel.Text = $t
    $ocrLabel.Enabled = $checks['ocr'].Checked
    $ocrList.Enabled = $checks['ocr'].Checked
  }

  $showPage = {
    param([int]$n)
    $p = & $selPurpose
    if ($n -eq 1) {
      $page2.Visible = $false
      $page1.Visible = $true
      $headTitle.Text = M 'Choose1_Title'
      $headSub.Text = M 'Choose1_Sub'
      $back.Visible = $false
      $next.Text = M 'Button_Next'
    } else {
      foreach ($c in $officeCtl) { $c.Visible = ($p -ne 'dev') }
      foreach ($c in $devCtl) { $c.Visible = ($p -ne 'office') }
      $devHead.Margin = New-Object Windows.Forms.Padding(0, $(if ($p -eq 'dev') { 4 } else { 22 }), 0, 0)
      & $updateSize
      $page1.Visible = $false
      $page2.Visible = $true
      $headTitle.Text = M 'Choose2_Title'
      $headSub.Text = M "Choose2_Sub_$p"
      $back.Visible = $true
      $next.Text = M 'Button_Install'
    }
    $form.Tag = $n
  }

  foreach ($c in $checks.Values) { $c.Add_CheckedChanged({ & $updateSize }) }
  $ocrList.Add_ItemCheck({ $form.BeginInvoke([Action] { & $updateSize }) | Out-Null })
  $back.Add_Click({ & $showPage 1 })
  $next.Add_Click({
      if ($form.Tag -eq 1) { & $showPage 2; return }
      if ((& $selPurpose) -ne 'dev' -and $checks['ocr'].Checked -and $ocrList.CheckedItems.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($form, (M 'Ocr_NeedLanguage'), (M 'App_Name'), 'OK', 'Information')
        return
      }
      $form.DialogResult = 'OK'
      $form.Close()
    })

  & $showPage 1
  $form.ResumeLayout()
  $result = $form.ShowDialog()
  if ($result -ne 'OK') { return $null }

  $p = & $selPurpose
  $office = @()
  $dev = @()
  $ocr = @()
  if ($p -ne 'dev') {
    $office = @($catalog.Office | Where-Object { $checks[$_.Id].Checked } | ForEach-Object { $_.Id })
    for ($i = 0; $i -lt $ocrList.Items.Count; $i++) {
      if ($ocrList.GetItemChecked($i)) { $ocr += $ocrCodes[$i] }
    }
  }
  if ($p -ne 'office') {
    $dev = @($catalog.Dev | Where-Object { $checks[$_.Id].Checked } | ForEach-Object { $_.Id })
  }
  if ($ocr.Count -eq 0) { $ocr = @('eng') }
  return @{ Purpose = $p; Office = $office; Dev = $dev; Ocr = $ocr }
}
