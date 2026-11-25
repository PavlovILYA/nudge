"""Original Nudge icon, drawn from geometry; Pillow is a development-only tool."""
from pathlib import Path
from PIL import Image, ImageDraw
import math

scale = 3
image = Image.new("RGB", (1024 * scale, 1024 * scale), "#191e28")
draw = ImageDraw.Draw(image)
def line(points, color, width):
    draw.line([(int(x * scale), int(y * scale)) for x, y in points], fill=color, width=int(width * scale))
    radius = width * scale / 2
    for x, y in (points[0], points[-1]):
        x, y = x * scale, y * scale
        draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=color)
def arc(box, start, end, color, width):
    draw.arc(tuple(int(v * scale) for v in box), start, end, fill=color, width=width * scale)

white = "#eaf0fa"
blue = "#4b9fff"
# A thick, open signal halo, a clock face and two small bells/feet.
arc((178, 178, 846, 846), 213, 327, blue, 25)
arc((269, 288, 755, 774), 0, 360, white, 38)
line([(512, 530), (512, 393)], white, 36)
line([(512, 530), (611, 586)], blue, 36)
line([(317, 282), (267, 336)], white, 43)
line([(707, 282), (757, 336)], white, 43)
line([(350, 735), (316, 785)], white, 36)
line([(674, 735), (708, 785)], white, 36)
image = image.resize((1024, 1024), Image.LANCZOS)
output = Path(__file__).resolve().parents[1] / "Nudge/Assets.xcassets/AppIcon.appiconset"
output.mkdir(parents=True, exist_ok=True)
image.save(output / "NudgeIcon.png")
(output / "Contents.json").write_text('''{
  "images" : [
    { "filename" : "NudgeIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
''')
