<?
error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED & ~E_STRICT);
class Foo { var $a; function Foo($x = 1) { $this->a = $x; } function get() { return $this->a; } }
class Bar extends Foo { function Bar() { parent::Foo(2); } }
class Baz extends Foo {}
abstract class Qux { function Qux() { $this->q = 'q'; } }
class Quux extends Qux {}
$s = "abc"; $c = $s{1}; $arr = array('k' => 'xyz'); $d = $arr['k']{0};
$o = new stdClass; $o->p = "qq"; $e = $o->p{0};
$chain = array(array("ab")); $f = $chain[0][0]{1};
$str = "val: $arr[k] and {$arr['k']} and $s{0} and {$s{2}}";
$h = <<<EOT
H:$arr[k] {$arr['k']}
EOT;
$x =& new Foo(3);
$r = (real) "1.5";
define('MYCONST', 'mk'); $m = array('mk' => 'const-ok'); $mm = $m[MYCONST];
$data = array('no' => 7, 'nm' => 'n', 'true' => 'T');
$q = new Quux; $_SERVER['WGT'] = 'srv'; $sv = $_SERVER[WGT];
echo implode('|', array($c, $d, $e, $f, $str, $h, $x->get(), $r, $mm, $data[no], $data[nm], $data[true] === null ? 'null' : 'x', $sv)), "\n";
$b = new Bar; $z = new Baz; echo $b->get(), $z->get(), $q->q, "\n";
?>
<?=$data[no]?> "<?=$s{0}?>" <? echo $data['nm'] ?>
