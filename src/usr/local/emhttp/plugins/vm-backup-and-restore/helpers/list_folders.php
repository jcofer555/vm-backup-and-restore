<?php
$base = "/mnt";

$path = $_GET['path'] ?? $base;
$path = realpath($path);

// Must stay inside /mnt
if ($path === false || strpos($path, $base) !== 0) {
    $path = $base;
}

$folders = [];

if (is_dir($path)) {
    foreach (scandir($path) as $item) {
        if ($item === '.' || $item === '..') continue;

        $full = $path . '/' . $item;

        if (is_dir($full)) {

            // Count depth
            $depth = substr_count(trim($full, '/'), '/');

            // selectable only if deeper than /mnt/*
            $selectable = ($depth >= 2); 
            // /mnt/disk1/test = 2 slashes = selectable

            $folders[] = [
                'name' => $item,
                'path' => $full,
                'selectable' => $selectable
            ];
        }
    }
}

echo json_encode([
    'current' => $path,
    'parent' => ($path !== $base) ? dirname($path) : null,
    'folders' => $folders
]);
