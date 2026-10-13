# Crop a region from a screenshot for detailed reading (full 2560x1440 shots lose small text).
param(
    [string]$In = 'D:\Code\Bear\gui\step14-restored.png',
    [string]$Out = 'D:\Code\Bear\gui\crop.png',
    [int]$X, [int]$Y, [int]$W, [int]$H,
    [double]$Zoom = 2.0
)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile($In)
$crop = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)),
    (New-Object System.Drawing.Rectangle($X, $Y, $W, $H)), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$big = New-Object System.Drawing.Bitmap([int]($W * $Zoom), [int]($H * $Zoom))
$g2 = [System.Drawing.Graphics]::FromImage($big)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.DrawImage($crop, 0, 0, $big.Width, $big.Height)
$g2.Dispose()
$big.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose(); $crop.Dispose(); $src.Dispose()
Write-Host "saved $Out ($W x $H -> x$Zoom)"
