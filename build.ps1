# =====================================================================
#  Dashboard Funil de Trafego (Meta Ads) - motor de dados
#  Cruza 3 planilhas (Queries x Leads x Vendas), aplica imposto e
#  gera data.js consumido pela pagina estatica. Somente leitura.
#  Roda local (Windows PowerShell) e em GitHub Actions (pwsh/powershell).
# =====================================================================
param([ValidateSet('all')][string]$Mode='all')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'; New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# ---- fontes ----
$QUERIES_ID='1RJC_VqNbRF8Xir_jQQ4KBdA0Bh9u4AUiDQPxr1sPEHU'; $QUERIES_GID='1160142252'
$MASTER_ID ='1WuETdVje43yvMfyQDHO1PObXj_G9G-t6JjG6q987Z4o'
$LEADS_GID ='2069413298'   # aba "Leads filtrados para trafego"
$KIWIFY_GID='1987730935'   # aba "clientes kiwify compra"
$TAX=1.1385

function Get-Sheet($id,$gid,$out){ Invoke-WebRequest -Uri "https://docs.google.com/spreadsheets/d/$id/gviz/tq?tqx=out:csv&gid=$gid" -OutFile $out -UseBasicParsing -TimeoutSec 120; if((Get-Item $out).Length -lt 50){ throw "download pequeno: $out" } }
Add-Type -AssemblyName Microsoft.VisualBasic
function Read-Csv($path){ $rows=New-Object System.Collections.Generic.List[object]
  $p=New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path,[System.Text.Encoding]::UTF8); $p.TextFieldType='Delimited'; $p.SetDelimiters(','); $p.HasFieldsEnclosedInQuotes=$true
  while(-not $p.EndOfData){ $rows.Add($p.ReadFields()) }; $p.Close(); return $rows }
function Norm($s){ if($null -eq $s){return ''}; return ($s -replace [char]0x200b,'').Trim() }
function MoneyBR($s){ $s=Norm $s; if($s -eq ''){return 0.0}; return [double]($s -replace '\.','' -replace ',','.') }
function MoneyKiwify($s){ $s=Norm $s; if($s -eq ''){return 0.0}
  if($s -match ','){ return [double](($s -replace '\.','') -replace ',','.') }
  if($s -match '\.'){ return [double]::Parse($s,[Globalization.CultureInfo]::InvariantCulture) }
  $v=[double]$s; if($v -ge 100000){ return $v/100 } else { return $v } }
function ToInt($s){ $s=Norm $s; if($s -eq ''){return 0}; return [int]([double]($s -replace '\.','' -replace ',','.')) }
function AdCode($s){ $s=Norm $s; if($s -match '(AD\d+)'){ return $Matches[1] }; return $s }
function HdrIndex($hdr,$name){ for($i=0;$i -lt $hdr.Count;$i++){ if((Norm $hdr[$i]) -eq $name){ return $i } }; return -1 }
function HdrLike($hdr,$pat){ for($i=0;$i -lt $hdr.Count;$i++){ if((Norm $hdr[$i]) -like $pat){ return $i } }; return -1 }
# escolhe a coluna de e-mail REAL (a com mais @) entre as colunas que parecem e-mail
function BestEmailCol($hdr,$rows){ $best=-1; $max=0
  for($i=0;$i -lt $hdr.Count;$i++){ if((Norm $hdr[$i]) -notlike '*mail*'){continue}
    $c=0; foreach($r in $rows){ if($i -lt $r.Count -and $r[$i] -match '@'){ $c++ } }
    if($c -gt $max){ $max=$c; $best=$i } }
  return $best }
function BrDate($s){ $s=Norm $s; if($s -match '^(\d{2})/(\d{2})/(\d{4})'){ return "$($Matches[3])-$($Matches[2])-$($Matches[1])" }; return '' }
function IsoDate($s){ $s=Norm $s; if($s -match '^(\d{4}-\d{2}-\d{2})'){ return $Matches[1] }; return '' }

Write-Host "Baixando planilhas..."
$qCsv=Join-Path $dataDir 'queries.csv'; $lCsv=Join-Path $dataDir 'leads.csv'; $kCsv=Join-Path $dataDir 'kiwify.csv'
Get-Sheet $QUERIES_ID $QUERIES_GID $qCsv; Get-Sheet $MASTER_ID $LEADS_GID $lCsv; Get-Sheet $MASTER_ID $KIWIFY_GID $kCsv
$q=Read-Csv $qCsv; $qh=$q[0]; $qd=$q[1..($q.Count-1)]
$l=Read-Csv $lCsv; $lh=$l[0]; $ld=$l[1..($l.Count-1)]
$k=Read-Csv $kCsv; $kh=$k[0]; $kd=$k[1..($k.Count-1)]

# ---- indices ----
$Q_DAY=HdrIndex $qh 'Day'; $Q_CAMP=HdrIndex $qh 'Campaign Name'; $Q_SET=HdrIndex $qh 'Ad Set Name'; $Q_AD=HdrIndex $qh 'Ad Name'
$Q_SPEND=HdrIndex $qh 'Amount Spent'; $Q_IMP=HdrIndex $qh 'Impressions'; $Q_CLK=HdrIndex $qh 'Link Clicks'; $Q_LPV=HdrIndex $qh 'Landing Page Views'
$L_EMAIL=BestEmailCol $lh $ld; $L_CAMP=HdrIndex $lh 'utm_campaign'; $L_SET=HdrIndex $lh 'utm_medium'; $L_CONT=HdrIndex $lh 'utm_content'
$L_DATE=HdrLike $lh '*Submitted*'   # "Submitted At" em DD/MM/YYYY HH:MM:SS
$K_STAT=HdrIndex $kh 'Status'; $K_EMAIL=HdrIndex $kh 'Email'; $K_DATE=HdrIndex $kh 'Data Simplificada'; $K_REV=HdrLike $kh 'Total com acr*'

# ---- DAILY (totais do funil) ----
$daily=@{}
function GetDay($d){ if(-not $daily.ContainsKey($d)){ $daily[$d]=[pscustomobject]@{date=$d;spend=0.0;impr=0;clicks=0;lpv=0;leads=0;sales=0;revenue=0.0} }; return $daily[$d] }
foreach($r in $qd){ $d=Norm $r[$Q_DAY]; if($d -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $o=GetDay $d; $o.spend+=(MoneyBR $r[$Q_SPEND])*$TAX; $o.impr+=ToInt $r[$Q_IMP]; $o.clicks+=ToInt $r[$Q_CLK]; $o.lpv+=ToInt $r[$Q_LPV] }
foreach($r in $ld){ $d=BrDate $r[$L_DATE]; if($d -eq ''){continue}; (GetDay $d).leads++ }
foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $d=BrDate $r[$K_DATE]; if($d -eq ''){continue}
  $o=GetDay $d; $o.sales++; $o.revenue+=(MoneyKiwify $r[$K_REV]) }

# ---- GRAIN (campanha/conjunto/anuncio) ----
$grain=@{}
function GetGrain($d,$c,$s,$a){ $key="$d`u$c`u$s`u$a"
  if(-not $grain.ContainsKey($key)){ $grain[$key]=[pscustomobject]@{date=$d;campaign=$c;adset=$s;ad=$a;spend=0.0;impr=0;clicks=0;lpv=0;leads=0;sales=0;revenue=0.0} }; return $grain[$key] }
foreach($r in $qd){ $d=Norm $r[$Q_DAY]; if($d -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $o=GetGrain $d (Norm $r[$Q_CAMP]) (Norm $r[$Q_SET]) (AdCode $r[$Q_AD])
  $o.spend+=(MoneyBR $r[$Q_SPEND])*$TAX; $o.impr+=ToInt $r[$Q_IMP]; $o.clicks+=ToInt $r[$Q_CLK]; $o.lpv+=ToInt $r[$Q_LPV] }
$leadByEmail=@{}
foreach($r in $ld){ $e=(Norm $r[$L_EMAIL]).ToLower(); if($e -eq ''){continue}
  $leadByEmail[$e]=[pscustomobject]@{campaign=(Norm $r[$L_CAMP]);adset=(Norm $r[$L_SET]);ad=(AdCode $r[$L_CONT])} }
foreach($r in $ld){ $d=BrDate $r[$L_DATE]; if($d -eq ''){continue}
  $c=Norm $r[$L_CAMP]; if($c -eq ''){$c='SEM_UTM'}; $s=Norm $r[$L_SET]; if($s -eq ''){$s='SEM_UTM'}; $a=AdCode $r[$L_CONT]; if($a -eq ''){$a='SEM_UTM'}
  (GetGrain $d $c $s $a).leads++ }
foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $d=BrDate $r[$K_DATE]; if($d -eq ''){continue}
  $e=(Norm $r[$K_EMAIL]).ToLower(); $rev=MoneyKiwify $r[$K_REV]
  if($e -ne '' -and $leadByEmail.ContainsKey($e)){ $m=$leadByEmail[$e]
    $c=if($m.campaign){$m.campaign}else{'NAO_ATRIBUIDO'}; $s=if($m.adset){$m.adset}else{'NAO_ATRIBUIDO'}; $a=if($m.ad){$m.ad}else{'NAO_ATRIBUIDO'}
    $o=GetGrain $d $c $s $a } else { $o=GetGrain $d 'NAO_ATRIBUIDO' 'NAO_ATRIBUIDO' 'NAO_ATRIBUIDO' }
  $o.sales++; $o.revenue+=$rev }

# ---- emit ----
$dailyArr=$daily.Values | Sort-Object date
$grainArr=$grain.Values | Where-Object { $_.leads -gt 0 -or $_.spend -gt 0 -or $_.sales -gt 0 } | Sort-Object date
$dates=$dailyArr.date | Sort-Object
$paid=($kd | Where-Object { (Norm $_[$K_STAT]) -eq 'paid' }).Count
$matched=0; foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $e=(Norm $r[$K_EMAIL]).ToLower(); if($e -ne '' -and $leadByEmail.ContainsKey($e)){ $matched++ } }
$nowBR=[System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'E. South America Standard Time').ToString('dd/MM/yyyy HH:mm')
$out=[pscustomobject]@{
  generatedAt=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); generatedAtBR=$nowBR; taxMultiplier=$TAX
  dateMin=$dates[0]; dateMax=$dates[-1]; buyersTotal=$paid; buyersMatched=$matched
  daily=$dailyArr; grain=$grainArr }
$json=$out | ConvertTo-Json -Depth 6 -Compress
$utf8=[System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $root 'data.js'), ("window.DASH_DATA="+$json+";"), $utf8)
Write-Host ("OK  dias={0}  grain={1}  vendas casadas={2}/{3}  periodo={4}..{5}" -f $dailyArr.Count,$grainArr.Count,$matched,$paid,$dates[0],$dates[-1])
