--TEST--
Symmetric Array Destructuring 01
--SKIPIF--
<?php
if (version_compare(PHP_VERSION, '7.1', '<')) exit("Skip This test is for PHP 7.1+.");
?>
--FILE--
<?php
class :x {}

[$x, $y] = [3,4];

var_dump($x, $y);
--EXPECT--
int(3)
int(4)
