# =====================================================================
#  Dashboard Funil de Trafego (Meta Ads) - motor de dados
#  Cruza 3 planilhas (Queries x Leads x Vendas), aplica imposto,
#  calcula leads qualificados (faturamento mensal > 100k), objecoes
#  dos qualificados e insights gerais. Gera data.js. Somente leitura.
# =====================================================================
param([ValidateSet('all')][string]$Mode='all')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'; New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$BR=[Globalization.CultureInfo]::GetCultureInfo('pt-BR')

# ---- fontes ----
$QUERIES_ID='1RJC_VqNbRF8Xir_jQQ4KBdA0Bh9u4AUiDQPxr1sPEHU'; $QUERIES_GID='1160142252'
$MASTER_ID ='1WuETdVje43yvMfyQDHO1PObXj_G9G-t6JjG6q987Z4o'
$LEADS_GID ='603619749'; $KIWIFY_GID='1987730935'   # aba "leads para trafego" (bate com a contagem manual)
$TAX=1.1385
$QUAL_MENSAL=@('Entre R$ 100 mil e R$ 200 mil','Acima de 200 mil')

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
function BestEmailCol($hdr,$rows){ $best=-1; $max=0
  for($i=0;$i -lt $hdr.Count;$i++){ if((Norm $hdr[$i]) -notlike '*mail*'){continue}
    $c=0; foreach($r in $rows){ if($i -lt $r.Count -and $r[$i] -match '@'){ $c++ } }; if($c -gt $max){ $max=$c; $best=$i } }; return $best }
function BrDate($s){ $s=Norm $s; if($s -match '^(\d{2})/(\d{2})/(\d{4})'){ return "$($Matches[3])-$($Matches[2])-$($Matches[1])" }; return '' }
function LeadDate($s){ $s=Norm $s; if($s -match '^(\d{4}-\d{2}-\d{2})'){ return $Matches[1] }; return (BrDate $s) }
function Deaccent($s){ if($null -eq $s){return ''}; $s=$s.Normalize([Text.NormalizationForm]::FormD); $sb=New-Object Text.StringBuilder
  foreach($c in $s.ToCharArray()){ if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark){ [void]$sb.Append($c) } }; return $sb.ToString().ToLower() }
$OBJ_BUCKETS=@(
  @('Equipe & Pessoas',       @('equipe','pessoa','mao de obra','colaborador','funcionario','contrat','lider','recursos humanos')),
  @('Delegacao & Escala',     @('deleg','escal','cresc','expand','expans','sair da operac','depend','sozinh','dono faz','centraliz','sobrecarg','estagn')),
  @('Financeiro & Capital',   @('financ','dinheiro','capital','fluxo de caixa','caixa','lucro','custo','precific','investiment',' giro','endivid','divida','inadimpl','preco')),
  @('Vendas & Clientes',      @('vend','client','captac','captar','prospec','fechar','convert','faturament','faturar','negocia','funil','orcament','comercial')),
  @('Marketing & Divulgacao', @('marketing','divulg','trafego','anunci','publicidad','digital','posicion','branding','rede social','redes sociais','instagram','alcance','visibilidade','seguidor','conteudo','comunica','reconheci')),
  @('Gestao & Organizacao',   @('gest','organiz','administr','process','controle','tempo','rotina','planejament','sistema','estrutur')),
  @('Estrategia & Direcao',   @('estrateg','direcionament','direcao','clareza','conheciment','rumo')),
  @('Mindset & Constancia',   @('medo','consist','constan','discipl','foco','mindset','inseguran','autoconf','procrastin','ansiedad','acredit','autoestima','motiva','coragem','desanim')),
  @('Concorrencia & Mercado', @('concorr','mercado','crise','economi','sazonal')),
  @('Produto & Operacao',     @('produt','estoque','operac','qualidade','entrega','logistic','fornecedor','servico')),
  @('Sem empresa / Inicio',   @('nao tenho empresa','sem empresa','comecar','comec','abrir empresa','iniciante','ainda nao','nao tenho','clt','salario','emprego','eu mesma'))
)
$OBJ_ORDER=@($OBJ_BUCKETS | ForEach-Object { $_[0] }) + 'Outros'
function Bucket($txt){ $t=Deaccent (Norm $txt); if($t -eq ''){return 'Outros'}
  foreach($b in $OBJ_BUCKETS){ foreach($kw in $b[1]){ if($t.Contains($kw)){ return $b[0] } } }; return 'Outros' }

Write-Host "Baixando planilhas..."
$qCsv=Join-Path $dataDir 'queries.csv'; $lCsv=Join-Path $dataDir 'leads.csv'; $kCsv=Join-Path $dataDir 'kiwify.csv'
Get-Sheet $QUERIES_ID $QUERIES_GID $qCsv; Get-Sheet $MASTER_ID $LEADS_GID $lCsv; Get-Sheet $MASTER_ID $KIWIFY_GID $kCsv
$q=Read-Csv $qCsv; $qh=$q[0]; $qd=$q[1..($q.Count-1)]
$l=Read-Csv $lCsv; $lh=$l[0]; $ld=$l[1..($l.Count-1)]
$k=Read-Csv $kCsv; $kh=$k[0]; $kd=$k[1..($k.Count-1)]

$Q_DAY=HdrIndex $qh 'Day'; $Q_CAMP=HdrIndex $qh 'Campaign Name'; $Q_SET=HdrIndex $qh 'Ad Set Name'; $Q_AD=HdrIndex $qh 'Ad Name'
$Q_SPEND=HdrIndex $qh 'Amount Spent'; $Q_IMP=HdrIndex $qh 'Impressions'; $Q_CLK=HdrIndex $qh 'Link Clicks'; $Q_LPV=HdrIndex $qh 'Landing Page Views'
$L_EMAIL=BestEmailCol $lh $ld; $L_CAMP=HdrIndex $lh 'utm_campaign'; $L_SET=HdrIndex $lh 'utm_medium'; $L_CONT=HdrIndex $lh 'utm_content'
$L_DATE=HdrIndex $lh 'Data Formatada'; if($L_DATE -lt 0){ $L_DATE=HdrLike $lh '*Submitted*' }
$L_FAT=HdrLike $lh '*faturamento mensal*'; $L_DESAFIO=HdrLike $lh '*principal desafio*'
$K_STAT=HdrIndex $kh 'Status'; $K_EMAIL=HdrIndex $kh 'Email'; $K_DATE=HdrIndex $kh 'Data Simplificada'; $K_REV=HdrLike $kh 'Total com acr*'

# ---- DAILY ----
$daily=@{}
function GetDay($d){ if(-not $daily.ContainsKey($d)){ $daily[$d]=[pscustomobject]@{date=$d;spend=0.0;impr=0;clicks=0;lpv=0;leads=0;qlf=0;sales=0;revenue=0.0} }; return $daily[$d] }
foreach($r in $qd){ $d=Norm $r[$Q_DAY]; if($d -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $o=GetDay $d; $o.spend+=(MoneyBR $r[$Q_SPEND])*$TAX; $o.impr+=ToInt $r[$Q_IMP]; $o.clicks+=ToInt $r[$Q_CLK]; $o.lpv+=ToInt $r[$Q_LPV] }
foreach($r in $ld){ $d=LeadDate $r[$L_DATE]; if($d -eq ''){continue}; $o=GetDay $d; $o.leads++; if((Norm $r[$L_FAT]) -in $QUAL_MENSAL){ $o.qlf++ } }
foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $d=BrDate $r[$K_DATE]; if($d -eq ''){continue}; $o=GetDay $d; $o.sales++; $o.revenue+=(MoneyKiwify $r[$K_REV]) }

# ---- GRAIN ----
$grain=@{}
function GetGrain($d,$c,$s,$a){ $key="$d`u$c`u$s`u$a"; if(-not $grain.ContainsKey($key)){ $grain[$key]=[pscustomobject]@{date=$d;campaign=$c;adset=$s;ad=$a;spend=0.0;impr=0;clicks=0;lpv=0;leads=0;qlf=0;sales=0;revenue=0.0} }; return $grain[$key] }
foreach($r in $qd){ $d=Norm $r[$Q_DAY]; if($d -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $o=GetGrain $d (Norm $r[$Q_CAMP]) (Norm $r[$Q_SET]) (AdCode $r[$Q_AD])
  $o.spend+=(MoneyBR $r[$Q_SPEND])*$TAX; $o.impr+=ToInt $r[$Q_IMP]; $o.clicks+=ToInt $r[$Q_CLK]; $o.lpv+=ToInt $r[$Q_LPV] }
$leadByEmail=@{}
foreach($r in $ld){ $e=(Norm $r[$L_EMAIL]).ToLower(); if($e -eq ''){continue}; $leadByEmail[$e]=[pscustomobject]@{campaign=(Norm $r[$L_CAMP]);adset=(Norm $r[$L_SET]);ad=(AdCode $r[$L_CONT])} }
# objecoes dos QUALIFICADOS (por dia x balde) + verbatims
$objQlf=@{}
function GetObj($d,$b){ $key="$d`u$b"; if(-not $objQlf.ContainsKey($key)){ $objQlf[$key]=[pscustomobject]@{date=$d;bucket=$b;qlf=0} }; return $objQlf[$key] }
$qVerb=@{}
foreach($r in $ld){ $d=LeadDate $r[$L_DATE]; if($d -eq ''){continue}
  $c=Norm $r[$L_CAMP]; if($c -eq ''){$c='SEM_UTM'}; $s=Norm $r[$L_SET]; if($s -eq ''){$s='SEM_UTM'}; $a=AdCode $r[$L_CONT]; if($a -eq ''){$a='SEM_UTM'}
  $o=GetGrain $d $c $s $a; $o.leads++
  $isq=(Norm $r[$L_FAT]) -in $QUAL_MENSAL
  if($isq){ $o.qlf++; $b=Bucket $r[$L_DESAFIO]; (GetObj $d $b).qlf++
    $t=Norm $r[$L_DESAFIO]
    if($t.Length -ge 3 -and $t.Length -le 160 -and $t -notmatch '@' -and $t -notmatch 'http' -and $t -notmatch '\d{4,}'){
      $col=($t.ToLower() -replace '\s',''); if(($col.ToCharArray()|Select-Object -Unique).Count -gt 1){
        if(-not $qVerb.ContainsKey($b)){ $qVerb[$b]=@{} }; if($qVerb[$b].ContainsKey($t)){ $qVerb[$b][$t]++ } else { $qVerb[$b][$t]=1 } } } } }
foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $d=BrDate $r[$K_DATE]; if($d -eq ''){continue}
  $e=(Norm $r[$K_EMAIL]).ToLower(); $rev=MoneyKiwify $r[$K_REV]
  if($e -ne '' -and $leadByEmail.ContainsKey($e)){ $m=$leadByEmail[$e]
    $c=if($m.campaign){$m.campaign}else{'NAO_ATRIBUIDO'}; $s=if($m.adset){$m.adset}else{'NAO_ATRIBUIDO'}; $a=if($m.ad){$m.ad}else{'NAO_ATRIBUIDO'}
    $o=GetGrain $d $c $s $a } else { $o=GetGrain $d 'NAO_ATRIBUIDO' 'NAO_ATRIBUIDO' 'NAO_ATRIBUIDO' }
  $o.sales++; $o.revenue+=$rev }
$objQuotes=foreach($b in $OBJ_ORDER){ if(-not $qVerb.ContainsKey($b)){continue}; $hh=$qVerb[$b]
  $terms=$hh.GetEnumerator() | Where-Object { $_.Value -ge 2 } | Sort-Object Value -Descending | Select-Object -First 12 | ForEach-Object { [pscustomobject]@{t=$_.Key;n=$_.Value} }
  $examples=$hh.Keys | Where-Object { $_.Length -ge 25 } | Sort-Object { $_.Length } -Descending | Select-Object -First 6
  [pscustomobject]@{bucket=$b;total=(($hh.Values|Measure-Object -Sum).Sum);terms=@($terms);examples=@($examples)} }

# ---- arrays + insights ----
$dailyArr=$daily.Values | Sort-Object date
$grainArr=$grain.Values | Where-Object { $_.leads -gt 0 -or $_.spend -gt 0 -or $_.sales -gt 0 } | Sort-Object date
$dates=$dailyArr.date | Sort-Object
$paid=($kd | Where-Object { (Norm $_[$K_STAT]) -eq 'paid' }).Count
$matched=0; foreach($r in $kd){ if((Norm $r[$K_STAT]) -ne 'paid'){continue}; $e=(Norm $r[$K_EMAIL]).ToLower(); if($e -ne '' -and $leadByEmail.ContainsKey($e)){ $matched++ } }

# INSIGHTS gerais (ultimos 30 dias) - dados estruturados; prosa no app.js
$dmax=$dates[-1]; $dt=[datetime]::ParseExact($dmax,'yyyy-MM-dd',$null); $w30=$dt.AddDays(-29).ToString('yyyy-MM-dd')
function Sdiv($a,$b){ if($b -gt 0){ return $a/$b } else { return 0 } }
$cur=[pscustomobject]@{spend=0.0;impr=0;clicks=0;lpv=0;leads=0;qlf=0;sales=0;revenue=0.0}
foreach($r in $dailyArr){ if($r.date -ge $w30 -and $r.date -le $dmax){ $cur.spend+=$r.spend;$cur.impr+=$r.impr;$cur.clicks+=$r.clicks;$cur.lpv+=$r.lpv;$cur.leads+=$r.leads;$cur.qlf+=$r.qlf;$cur.sales+=$r.sales;$cur.revenue+=$r.revenue } }
$ins=New-Object System.Collections.Generic.List[object]
function AddIns($o){ $ins.Add([pscustomobject]$o) }
AddIns @{type='funnel_qualrate';cat='funil';rate=[math]::Round((Sdiv $cur.qlf $cur.leads)*100,1);qlf=[int]$cur.qlf;leads=[int]$cur.leads}
AddIns @{type='funnel_cplqlf';cat='funil';cplqlf=[math]::Round((Sdiv $cur.spend $cur.qlf),2)}
AddIns @{type='funnel_cpl';cat='funil';cpl=[math]::Round((Sdiv $cur.spend $cur.leads),2)}
if($cur.sales -gt 0){ AddIns @{type='funnel_cac';cat='funil';cac=[math]::Round((Sdiv $cur.spend $cur.sales),2);ticket=[math]::Round((Sdiv $cur.revenue $cur.sales),2);roas=[math]::Round((Sdiv $cur.revenue $cur.spend),2)} }
AddIns @{type='funnel_convlp';cat='funil';convlp=[math]::Round((Sdiv $cur.leads $cur.lpv)*100,1)}
# campanhas (30d)
$campW=@{}
foreach($r in $grainArr){ if($r.date -lt $w30 -or $r.date -gt $dmax){continue}; if($r.campaign -in @('SEM_UTM','NAO_ATRIBUIDO') -or $r.campaign -like '*{*'){continue}
  if(-not $campW.ContainsKey($r.campaign)){ $campW[$r.campaign]=[pscustomobject]@{c=$r.campaign;spend=0.0;leads=0;qlf=0;sales=0} }
  $o=$campW[$r.campaign];$o.spend+=$r.spend;$o.leads+=$r.leads;$o.qlf+=$r.qlf;$o.sales+=$r.sales }
$ca=@($campW.Values)
$cheap=$ca | Where-Object { $_.qlf -ge 5 -and $_.spend -gt 0 } | Sort-Object { $_.spend/$_.qlf } | Select-Object -First 1
if($cheap){ AddIns @{type='camp_cheap';cat='campanhas';campaign=$cheap.c;cplqlf=[math]::Round($cheap.spend/$cheap.qlf,2);qlf=$cheap.qlf} }
$exp=$ca | Where-Object { $_.qlf -ge 1 -and $_.spend -ge 500 -and ($_.spend/$_.qlf) -gt 150 } | Sort-Object { $_.spend/$_.qlf } -Descending | Select-Object -First 1
if($exp){ AddIns @{type='camp_exp';cat='campanhas';campaign=$exp.c;cplqlf=[math]::Round($exp.spend/$exp.qlf,2);spend=[math]::Round($exp.spend,2)} }
$bs=$ca | Where-Object { $_.sales -ge 2 } | Sort-Object sales -Descending | Select-Object -First 1
if($bs){ AddIns @{type='camp_sales';cat='campanhas';campaign=$bs.c;sales=$bs.sales;cac=[math]::Round((Sdiv $bs.spend $bs.sales),2)} }
# objecao top dos qualificados (todo periodo)
$Qb=@{}; foreach($b in $OBJ_ORDER){$Qb[$b]=0}; foreach($r in $objQlf.Values){ $Qb[$r.bucket]+=$r.qlf }
$totQ=0; foreach($v in $Qb.Values){$totQ+=$v}
$topObj=$Qb.GetEnumerator() | Where-Object { $_.Key -ne 'Outros' } | Sort-Object Value -Descending | Select-Object -First 1
if($topObj -and $totQ -gt 0){ AddIns @{type='obj_top';cat='objecoes';bucket=$topObj.Key;pct=[math]::Round($topObj.Value/$totQ*100,1);n=$topObj.Value} }

# ---- emit ----
$nowBR=[System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'E. South America Standard Time').ToString('dd/MM/yyyy HH:mm')
$out=[pscustomobject]@{
  generatedAt=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); generatedAtBR=$nowBR; taxMultiplier=$TAX
  qualification='Faturamento mensal acima de R$ 100 mil'
  dateMin=$dates[0]; dateMax=$dates[-1]; buyersTotal=$paid; buyersMatched=$matched; windowStart=$w30; windowEnd=$dmax
  objOrder=$OBJ_ORDER; daily=$dailyArr; grain=$grainArr; objQlf=($objQlf.Values|Sort-Object date); objQuotes=@($objQuotes) }
$utf8=[System.Text.UTF8Encoding]::new($false)
# array de insights serializado item a item (evita bug do ConvertTo-Json 5.1 com heterogeneo)
$parts=@(); foreach($it in $ins){ $parts += ($it | ConvertTo-Json -Depth 4 -Compress) }
$mainJson=($out | ConvertTo-Json -Depth 8 -Compress)
$mainJson=$mainJson.Substring(0,$mainJson.Length-1) + ',"insights":[' + ($parts -join ',') + ']}'
[IO.File]::WriteAllText((Join-Path $root 'data.js'), ("window.DASH_DATA="+$mainJson+";"), $utf8)
Write-Host ("OK  dias={0}  grain={1}  qualif(total)={2}  vendas casadas={3}/{4}  insights={5}" -f $dailyArr.Count,$grainArr.Count,$totQ,$matched,$paid,$ins.Count)
