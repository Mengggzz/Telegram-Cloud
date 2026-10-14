from PIL import Image, ImageDraw, ImageFilter
import math
import os

def create_tgcloud_logo(size=1024):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    center_x = size / 2
    center_y = size / 2

    # 1. Outer squircle (rounded rectangle)
    margin = size * 0.05
    rect = [margin, margin, size - margin, size - margin]
    radius = size * 0.22

    # Background charcoal #121214
    bg_color = (18, 18, 20, 255)
    draw.rounded_rectangle(rect, radius=int(radius), fill=bg_color)

    # Subtle metallic border #2A2A30
    draw.rounded_rectangle(rect, radius=int(radius), outline=(42, 42, 48, 255), width=int(size * 0.015))

    # Inner subtle glow ring
    glow_color = (255, 152, 0, 25)
    inner_rect = [margin + size*0.02, margin + size*0.02, size - margin - size*0.02, size - margin - size*0.02]
    draw.rounded_rectangle(inner_rect, radius=int(radius * 0.9), outline=glow_color, width=int(size * 0.02))

    # 2. Cloud Silhouette (Amber neon / glowing outline)
    # Cloud consists of 3 circles and a rounded base
    # Center circle: (center_x, center_y - size*0.06), radius ~ size*0.20
    # Left circle: (center_x - size*0.16, center_y + size*0.02), radius ~ size*0.14
    # Right circle: (center_x + size*0.17, center_y + size*0.04), radius ~ size*0.12
    # Base pill: from left to right at center_y + size*0.10

    c_top_x = center_x - size * 0.02
    c_top_y = center_y - size * 0.08
    r_top = size * 0.20

    c_left_x = center_x - size * 0.20
    c_left_y = center_y + size * 0.04
    r_left = size * 0.14

    c_right_x = center_x + size * 0.18
    c_right_y = center_y + size * 0.06
    r_right = size * 0.12

    cloud_base_y1 = center_y - size * 0.02
    cloud_base_y2 = center_y + size * 0.18
    cloud_base_x1 = c_left_x - r_left
    cloud_base_x2 = c_right_x + r_right

    # Draw cloud body fill in darker elevated surface #222226
    cloud_surface = (30, 30, 35, 255)
    draw.ellipse([c_top_x - r_top, c_top_y - r_top, c_top_x + r_top, c_top_y + r_top], fill=cloud_surface)
    draw.ellipse([c_left_x - r_left, c_left_y - r_left, c_left_x + r_left, c_left_y + r_left], fill=cloud_surface)
    draw.ellipse([c_right_x - r_right, c_right_y - r_right, c_right_x + r_right, c_right_y + r_right], fill=cloud_surface)
    draw.rounded_rectangle([cloud_base_x1, cloud_base_y1, cloud_base_x2, cloud_base_y2], radius=int(size*0.08), fill=cloud_surface)

    # Cloud border glowing amber outline
    border_w = int(size * 0.028)
    amber_primary = (255, 152, 0, 255)
    amber_glow = (255, 171, 0, 60)

    # Faint outer aura
    draw.ellipse([c_top_x - r_top, c_top_y - r_top, c_top_x + r_top, c_top_y + r_top], outline=amber_glow, width=border_w*2)
    draw.ellipse([c_left_x - r_left, c_left_y - r_left, c_left_x + r_left, c_left_y + r_left], outline=amber_glow, width=border_w*2)
    draw.ellipse([c_right_x - r_right, c_right_y - r_right, c_right_x + r_right, c_right_y + r_right], outline=amber_glow, width=border_w*2)

    # Primary sharp border
    draw.ellipse([c_top_x - r_top, c_top_y - r_top, c_top_x + r_top, c_top_y + r_top], outline=amber_primary, width=border_w)
    draw.ellipse([c_left_x - r_left, c_left_y - r_left, c_left_x + r_left, c_left_y + r_left], outline=amber_primary, width=border_w)
    draw.ellipse([c_right_x - r_right, c_right_y - r_right, c_right_x + r_right, c_right_y + r_right], outline=amber_primary, width=border_w)
    draw.rounded_rectangle([cloud_base_x1, cloud_base_y1, cloud_base_x2, cloud_base_y2], radius=int(size*0.08), outline=amber_primary, width=border_w)

    # Refill inside of cloud so overlapping borders don't show internally
    inner_pad = border_w // 2
    draw.ellipse([c_top_x - r_top + inner_pad, c_top_y - r_top + inner_pad, c_top_x + r_top - inner_pad, c_top_y + r_top - inner_pad], fill=cloud_surface)
    draw.ellipse([c_left_x - r_left + inner_pad, c_left_y - r_left + inner_pad, c_left_x + r_left - inner_pad, c_left_y + r_left - inner_pad], fill=cloud_surface)
    draw.ellipse([c_right_x - r_right + inner_pad, c_right_y - r_right + inner_pad, c_right_x + r_right - inner_pad, c_right_y + r_right - inner_pad], fill=cloud_surface)
    draw.rounded_rectangle([cloud_base_x1 + inner_pad, cloud_base_y1 + inner_pad, cloud_base_x2 - inner_pad, cloud_base_y2 - inner_pad], radius=int(size*0.07), fill=cloud_surface)

    # 3. Inside the Cloud: Telegram Paper Plane Icon in Amber Gold Gradient (#FFB74D & #FF9800)
    # Paper plane points
    # Nose (top right): (center_x + size*0.14, center_y - size*0.03)
    # Left tail: (center_x - size*0.12, center_y - size*0.01)
    # Bottom corner: (center_x - size*0.02, center_y + size*0.13)
    # Indent point: (center_x + size*0.01, center_y + size*0.05)

    nose = (center_x + size * 0.13, center_y - size * 0.04)
    left_wing = (center_x - size * 0.12, center_y - size * 0.02)
    bottom_fold = (center_x - size * 0.02, center_y + size * 0.11)
    inner_fold = (center_x + size * 0.02, center_y + size * 0.04)

    # Shadow under plane
    shadow_offset = size * 0.015
    draw.polygon([
        (nose[0] + shadow_offset, nose[1] + shadow_offset),
        (left_wing[0] + shadow_offset, left_wing[1] + shadow_offset),
        (bottom_fold[0] + shadow_offset, bottom_fold[1] + shadow_offset)
    ], fill=(12, 12, 14, 200))

    # Main wing (top flap) - bright amber #FFB74D
    draw.polygon([nose, left_wing, inner_fold], fill=(255, 183, 77, 255))

    # Lower wing (bottom flap) - deep amber #FF9800
    draw.polygon([nose, inner_fold, bottom_fold], fill=(255, 152, 0, 255))

    # Left underside triangle - darker accent #E65100
    draw.polygon([left_wing, inner_fold, (center_x - size*0.03, center_y + size*0.03)], fill=(230, 81, 0, 255))

    # 4. Minimalist Security Lock Emblem at bottom-right corner
    lock_cx = size * 0.74
    lock_cy = size * 0.74
    lock_w = size * 0.18
    lock_h = size * 0.16

    # Lock backing circle
    draw.ellipse([lock_cx - size*0.14, lock_cy - size*0.14, lock_cx + size*0.14, lock_cy + size*0.14],
                 fill=(22, 22, 26, 255), outline=amber_primary, width=int(size*0.018))

    # Lock shackle (arc)
    shackle_bbox = [lock_cx - size*0.05, lock_cy - size*0.10, lock_cx + size*0.05, lock_cy]
    draw.arc(shackle_bbox, start=180, end=0, fill=(255, 183, 77, 255), width=int(size*0.02))

    # Lock body (rounded rect)
    draw.rounded_rectangle([lock_cx - size*0.07, lock_cy - size*0.02, lock_cx + size*0.07, lock_cy + size*0.08],
                           radius=int(size*0.02), fill=(255, 152, 0, 255))

    # Keyhole
    draw.ellipse([lock_cx - size*0.018, lock_cy + size*0.01, lock_cx + size*0.018, lock_cy + size*0.036], fill=(20, 20, 20, 255))
    draw.polygon([
        (lock_cx - size*0.012, lock_cy + size*0.025),
        (lock_cx + size*0.012, lock_cy + size*0.025),
        (lock_cx + size*0.016, lock_cy + size*0.055),
        (lock_cx - size*0.016, lock_cy + size*0.055)
    ], fill=(20, 20, 20, 255))

    return img

if __name__ == '__main__':
    base_dir = "C:/Users/NAN/Desktop/tgcloud"
    os.makedirs(f"{base_dir}/assets", exist_ok=True)
    
    logo = create_tgcloud_logo(1024)
    logo_path = f"{base_dir}/assets/logo.png"
    logo.save(logo_path, format="PNG")
    print(f"Generated master logo at {logo_path}")

    # Generate Android launcher icons
    mipmaps = {
        'mipmap-mdpi': 48,
        'mipmap-hdpi': 72,
        'mipmap-xhdpi': 96,
        'mipmap-xxhdpi': 144,
        'mipmap-xxxhdpi': 192,
    }

    res_dir = f"{base_dir}/android/app/src/main/res"
    for folder, px in mipmaps.items():
        resized = logo.resize((px, px), Image.Resampling.LANCZOS)
        out_path = f"{res_dir}/{folder}/ic_launcher.png"
        resized.save(out_path, format="PNG")
        print(f"Generated {out_path} ({px}x{px})")

    # Generate web icons
    web_icons = {
        f"{base_dir}/web/favicon.png": 32,
        f"{base_dir}/web/icons/Icon-192.png": 192,
        f"{base_dir}/web/icons/Icon-512.png": 512,
        f"{base_dir}/web/icons/Icon-maskable-192.png": 192,
        f"{base_dir}/web/icons/Icon-maskable-512.png": 512,
    }
    for path, px in web_icons.items():
        if os.path.exists(os.path.dirname(path)):
            resized = logo.resize((px, px), Image.Resampling.LANCZOS)
            resized.save(path, format="PNG")
            print(f"Generated web icon {path} ({px}x{px})")
