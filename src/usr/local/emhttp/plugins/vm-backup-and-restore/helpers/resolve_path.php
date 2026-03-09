<?php
declare(strict_types=1);
header('Content-Type: text/plain');

$path_str = $_POST['path'] ?? '';

if ($path_str === '') {
    echo '';
    exit;
}

$resolved_str = realpath($path_str);

echo ($resolved_str !== false) ? $resolved_str : $path_str;
