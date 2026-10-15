"""Render the project's original geometric icon. Requires Pillow; no input artwork."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
POINTS = [(40,128),(74,128),(100,78),(128,180),(156,104),(178,128),(216,128)]


def render(size):
    scale = 4
    canvas = Image.new('RGBA', (256*scale,256*scale))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((0,0,256*scale-1,256*scale-1), radius=64*scale, fill='#A9586D')
    draw.line([(x*scale,y*scale) for x,y in POINTS], fill='#FFF8F3', width=16*scale, joint='curve')
    for x,y in POINTS:
        draw.ellipse(((x-8)*scale,(y-8)*scale,(x+8)*scale,(y+8)*scale), fill='#FFF8F3')
    return canvas.resize((size,size), Image.Resampling.LANCZOS)


if __name__ == '__main__':
    for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
        render(size).save(ROOT/f'app/android/app/src/main/res/mipmap-{density}/ic_launcher.png')
    render(256).save(ROOT/'app/windows/runner/resources/app_icon.ico', sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
