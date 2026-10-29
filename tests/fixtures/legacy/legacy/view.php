<?php
$no = isset($_GET['no']) ? (int)$_GET['no'] : 0;
$link = mysql_connect("db", "zbuser", "zbpass123");
mysql_select_db("zbdb");
$r = mysql_query("select subject from zetyx_board_board1 where no=" . $no);
$d = mysql_fetch_row($r);
$title = $d[0];
echo '<html><head><meta http-equiv="Content-Type" content="text/html; charset=euc-kr"></head><body>';
echo "<h3>" . htmlspecialchars($title) . "</h3>";
echo "<p>len=" . strlen($title) . " " . mysql_escape_string("it's") . "</p></body></html>";
?>
