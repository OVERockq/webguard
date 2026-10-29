<?
// zeroboard4 style library (test fixture)
function zb_connect() {
  $f = file(dirname(__FILE__)."/config.php");
  $conn = mysql_connect(trim($f[1]), trim($f[2]), trim($f[3])) or die("DB 접속 실패");
  mysql_select_db(trim($f[4]), $conn);
  return $conn;
}
function del_html($str) { return htmlspecialchars($str); }
function check_id($id) { return eregi("^[a-z0-9_]+$", $id); }
?>
