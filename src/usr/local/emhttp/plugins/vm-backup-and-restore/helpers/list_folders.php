<?php
declare(strict_types=1);
header('Content-Type: application/json');

const BASE_PATH = '/mnt';

$raw_path_str = $_GET['path']  ?? BASE_PATH;
$field_str    = $_GET['field'] ?? '';

$path_str = realpath($raw_path_str);

// Constrain to /mnt
if ($path_str === false || strpos($path_str, BASE_PATH) !== 0) {
    $path_str = BASE_PATH;
}

$folders_arr = [];

if (is_dir($path_str)) {
    foreach (scandir($path_str) as $item_str) {
        if ($item_str === '.' || $item_str === '..') {
            continue;
        }

        $full_path_str = $path_str . '/' . $item_str;

        if (!is_dir($full_path_str)) {
            continue;
        }

        // Compute depth relative to /mnt
        $relative_str = trim(str_replace(BASE_PATH, '', $full_path_str), '/');
        $depth_int    = $relative_str === '' ? 0 : count(explode('/', $relative_str));

        $selectable_bool = ($depth_int >= 3);

        // restore_destination allows depth 2
        if ($field_str === 'restore_destination' && $depth_int === 2) {
            $selectable_bool = true;
        }

        $folders_arr[] = [
            'name'       => $item_str,
            'path'       => $full_path_str,
            'selectable' => $selectable_bool,
        ];
    }
}

echo json_encode([
    'current' => $path_str,
    'parent'  => ($path_str !== BASE_PATH) ? dirname($path_str) : null,
    'folders' => $folders_arr,
]);
