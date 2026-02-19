<?php
header('Content-Type: text/plain');

$path = $_POST['path'] ?? '';

if ($path === '') {
    echo '';
    exit;
}

$resolved = realpath($path);

// Only replace if resolution succeeded
echo $resolved !== false ? $resolved : $path;
