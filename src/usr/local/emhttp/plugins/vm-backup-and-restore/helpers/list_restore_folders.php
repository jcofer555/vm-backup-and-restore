<?php
header('Content-Type: application/json');

// Path coming from WebUI
$restorePath = rtrim($_GET['restore_path'] ?? '', '/');

// Validate input
if ($restorePath === '') {
    echo json_encode([
        'folders' => [],
        'error' => 'Restore path is empty'
    ]);
    exit;
}

// Must exist and be a directory
if (!is_dir($restorePath)) {
    echo json_encode([
        'folders' => [],
        'error' => "Invalid restore path: $restorePath"
    ]);
    exit;
}

// Safety: path must be under /mnt
if (strpos($restorePath, '/mnt') !== 0) {
    echo json_encode([
        'folders' => [],
        'error' => 'Restore path must be under /mnt'
    ]);
    exit;
}

// Scan directory
$folders = array_filter(scandir($restorePath), function ($item) use ($restorePath) {
    if ($item === '.' || $item === '..' || $item === 'logs') {
        return false;
    }

    $full = $restorePath . '/' . $item;
    if (!is_dir($full)) {
        return false;
    }

    // Required extensions
    $required = ['fd', 'img', 'xml'];
    $found = [
        'fd'  => false,
        'img' => false,
        'xml' => false,
    ];

    // Scan folder contents
    foreach (scandir($full) as $file) {
        $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
        if (isset($found[$ext])) {
            $found[$ext] = true;
        }
    }

    // Only include folder if all required file types exist
    return $found['fd'] && $found['img'] && $found['xml'];
});

// Return folder names
echo json_encode([
    'folders' => array_values($folders)
]);
