# Generates a synthetic two-column "paper" PDF for testing the reader.
# Usage: powershell -File make_test_pdf.ps1 -Out test_paper.pdf
param([string]$Out = "test_paper.pdf")

$words = ("the model reads each line of the paper in order while the reader follows a highlight that moves " +
  "forward with every tap on the right side of the screen and back with a tap on the left side we evaluate " +
  "layout analysis on two column documents with headings captions and running headers results show that " +
  "ordering lines by column and band keeps the reading flow natural for scientific articles").Split(" ")

$script:seed = 7
function Next-Word { $script:seed = ($script:seed * 1103515245 + 12345) % 2147483648; return $words[$script:seed % $words.Length] }

function Make-Lines([int]$count, [int]$chars) {
  $out = @(); $cur = ""
  while ($out.Count -lt $count) {
    $w = Next-Word
    if (($cur.Length + $w.Length + 1) -gt $chars) { $out += $cur; $cur = $w } else { $cur = ($cur + " " + $w).Trim() }
  }
  return $out
}

function Esc([string]$s) { return $s.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)') }
function TextOp([string]$font, [double]$size, [double]$x, [double]$y, [string]$s) {
  return "BT /$font $size Tf $x $y Td ($(Esc $s)) Tj ET`n"
}

$pageCount = 3
$streams = @()
$secNo = 1
for ($p = 0; $p -lt $pageCount; $p++) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append((TextOp "F1" 8 54 760 "Preprint. Under review as a workshop paper."))
  [void]$sb.Append((TextOp "F1" 9 300 36 "$($p + 1)"))
  $top = 730
  if ($p -eq 0) {
    [void]$sb.Append((TextOp "F2" 18 120 718 "Line by Line Reading of Scientific Papers"))
    [void]$sb.Append((TextOp "F1" 11 200 696 "A. Author, B. Author and C. Author"))
    [void]$sb.Append((TextOp "F2" 11 284 668 "Abstract"))
    $y = 652
    foreach ($l in (Make-Lines 5 100)) { [void]$sb.Append((TextOp "F1" 10 72 $y $l)); $y -= 12 }
    $top = 580
  }
  foreach ($x in @(54, 315)) {
    $y = $top
    while ($y -gt 70) {
      if ((($y -eq $top) -and ($x -eq 54)) -or ($y -lt $top -and ($y % 168) -lt 12)) {
        [void]$sb.Append((TextOp "F2" 11 $x $y "$secNo  Section Title Number $secNo")); $secNo++; $y -= 16
        continue
      }
      $l = @(Make-Lines 1 46)[0]
      [void]$sb.Append((TextOp "F1" 10 $x $y $l)); $y -= 12
    }
  }
  $streams += $sb.ToString()
}

# Assemble the PDF.
$objs = New-Object System.Collections.Generic.List[string]
$objs.Add("<< /Type /Catalog /Pages 2 0 R >>")
$kids = (0..($pageCount - 1) | ForEach-Object { "$(5 + $_ * 2) 0 R" }) -join " "
$objs.Add("<< /Type /Pages /Kids [$kids] /Count $pageCount >>")
$objs.Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
$objs.Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
for ($p = 0; $p -lt $pageCount; $p++) {
  $content = 6 + $p * 2
  $objs.Add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents $content 0 R >>")
  $s = $streams[$p]
  $objs.Add("<< /Length $([Text.Encoding]::ASCII.GetByteCount($s)) >>`nstream`n$s`nendstream")
}

$pdf = New-Object System.Text.StringBuilder
[void]$pdf.Append("%PDF-1.4`n")
$offsets = @()
for ($i = 0; $i -lt $objs.Count; $i++) {
  $offsets += [Text.Encoding]::ASCII.GetByteCount($pdf.ToString())
  [void]$pdf.Append("$($i + 1) 0 obj`n$($objs[$i])`nendobj`n")
}
$xref = [Text.Encoding]::ASCII.GetByteCount($pdf.ToString())
[void]$pdf.Append("xref`n0 $($objs.Count + 1)`n0000000000 65535 f `n")
foreach ($o in $offsets) { [void]$pdf.Append(("{0:D10} 00000 n `n" -f $o)) }
[void]$pdf.Append("trailer`n<< /Size $($objs.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
[IO.File]::WriteAllBytes($Out, [Text.Encoding]::ASCII.GetBytes($pdf.ToString()))
"Wrote $Out ($((Get-Item $Out).Length) bytes)"
