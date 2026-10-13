# Crop a region from a screenshot for detailed reading (a full-screen shot loses small text).
param(
    [Parameter(Mandatory = $true)][string]$In,
    # Defaults to <input>-crop.png beside the input.
    [string]$Out = '',
    # Required: without them the crop is an empty bitmap, which fails inside System.Drawing with a
    # message that says nothing about the missing arguments.
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [Parameter(Mandatory = $true)][int]$W,
    [Parameter(Mandatory = $true)][int]$H,
    [double]$Zoom = 2.0
)
Add-Type -AssemblyName System.Drawing

if ($Out -eq '') {
    $Out = Join-Path (Split-Path -Parent $In) `
        ([System.IO.Path]::GetFileNameWithoutExtension($In) + '-crop.png')
}

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
