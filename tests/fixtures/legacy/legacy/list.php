<?
// legacy page using removed APIs (PHP 4/5 era)
class ListPage {
  var $title;
  function ListPage($t = "목록") { $this->title = $t; }
  function head() { return "<h2>".$this->title."</h2>"; }
}
$page =& new ListPage();
$conn = mysql_connect("db", "zbuser", "zbpass123");
mysql_select_db("zbdb", $conn);
$res = mysql_query("select no, subject, name from zetyx_board_board1 order by no");
$names = array();
while ($row = mysql_fetch_assoc($res)) { $names[] = $row; }
$parts = split(",", "a,b,c");
$first = $parts[0];
$s = "hello";
$c = $s{0};
$arr = array("x" => 1, "y" => 2);
reset($arr);
$keys = "";
while (list($k, $v) = each($arr)) { $keys .= $k; }
$up = create_function('$a', 'return strtoupper($a);');
if (ereg("^[0-9]+$", "12345")) $num = "num";
$q = get_magic_quotes_gpc() ? "on" : "off";
?>
<html><head><meta http-equiv="Content-Type" content="text/html; charset=euc-kr"></head><body>
<?=$page->head()?>
<? foreach ($names as $r) { ?><div><?=$r['no']?> <?=htmlspecialchars($r['subject'])?> (<?=htmlspecialchars($r['name'])?>)</div><? } ?>
<p>first=<?=$first?> c=<?=$c?> keys=<?=$keys?> up=<?=$up("ok")?> <?=$num?> mq=<?=$q?></p>
<p>count=<?=mysql_num_rows($res)?> sel=<?=mysql_result($res, 0, 'subject') !== false ? 'y' : 'n'?></p>
</body></html>
