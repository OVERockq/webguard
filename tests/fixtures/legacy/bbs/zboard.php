<?
include "lib.php";
$id = $_GET[id];
$ref = $HTTP_SERVER_VARS[HTTP_REFERER];
if(!check_id($id)) die("잘못된 게시판");
$conn = zb_connect();
$result = mysql_query("select no, subject from zetyx_board_".$id." order by no desc", $conn);
?>
<html><head><meta http-equiv="Content-Type" content="text/html; charset=euc-kr"><title>board</title></head><body>
<h1><?=del_html($id)?></h1>
<ul>
<? while($data = mysql_fetch_array($result)) { ?>
<li><?=$data[no]?>. <?=del_html($data[subject])?></li>
<? } ?>
</ul>
<p>total: <?=mysql_num_rows($result)?></p>
</body></html>
