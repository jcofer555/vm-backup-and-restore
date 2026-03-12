<?php
declare(strict_types=1);
header('Content-Type: application/json');

const BASE_PATH = '/mnt';

$raw_path_str = $_GET['path']  ?? BASE_PATH;
$field_str    = $_GET['field'] ?? '';

// Sanitize without realpath() so /mnt/user/... symlinks are NOT resolved
// to their physical /mnt/cache/... equivalent — preserving correct mount-type
// classification in the UI.
$path_str = rtrim($raw_path_str, '/');
if (!str_starts_with($path_str, BASE_PATH) || !is_dir($path_str)) {
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

        // Compute depth relative to /mnt — count path segments, not realpath
        $relative_str = trim(str_replace(BASE_PATH, '', $full_path_str), '/');
        $depth_int    = $relative_str === '' ? 0 : count(explode('/', $relative_str));

        $selectable_bool = ($depth_int >= 3);

        // restore_destination allows one level shallower (depth 2)
        if ($field_str === 'vmbr-restore-destination' && $depth_int === 2) {
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