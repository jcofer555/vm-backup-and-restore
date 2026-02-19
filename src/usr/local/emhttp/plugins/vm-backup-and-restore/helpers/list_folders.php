<?php
$base = "/mnt";

$path  = $_GET['path']  ?? $base;
$field = $_GET['field'] ?? '';   // which input field triggered the picker

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

            // Compute depth relative to /mnt
            $relative = trim(str_replace($base, '', $full), '/');
            $parts = $relative === '' ? [] : explode('/', $relative);
            $depth = count($parts);

            /* -----------------------------
               Selection Rules
            ----------------------------- */

            // Default: depth < 3 → not selectable
            $selectable = ($depth >= 3);

            // Exception: restore_destination allows depth 2
            if ($field === 'restore_destination' && $depth === 2) {
                $selectable = true;
            }

            $folders[] = [
                'name'       => $item,
                'path'       => $full,
                'selectable' => $selectable
            ];
        }
    }
}

echo json_encode([
    'current' => $path,
    'parent'  => ($path !== $base) ? dirname($path) : null,
    'folders' => $folders
]);
