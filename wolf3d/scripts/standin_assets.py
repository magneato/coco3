"""Original procedural art and a small map for builds without Wolfenstein data."""
from PIL import Image, ImageDraw, ImageFont

LEVELS = (0, 85, 170, 255)
PALETTE = [(r, g, b) for r in LEVELS for g in LEVELS for b in LEVELS] * 4
TRANSPARENT = 255


def color_id(rgb):
    return min(range(64), key=lambda i: sum((PALETTE[i][k] - rgb[k]) ** 2 for k in range(3)))


def _grid(image):
    px = image.load()
    return [[None if px[x, y] == TRANSPARENT else px[x, y] for x in range(64)] for y in range(64)]


def _sprite_base():
    image = Image.new("L", (64, 64), TRANSPARENT)
    return image, ImageDraw.Draw(image)


def _c(rgb):
    return color_id(rgb)


class VSwap:
    """Provide the wall and sprite calls used by gen_assets.py without proprietary source data."""

    def wall(self, chunk):
        theme = chunk // 2
        shade = chunk & 1
        if chunk >= 102:
            theme = 14
        elif chunk >= 98:
            theme = 13
        palette = [
            ((70, 70, 85), (125, 125, 140), (35, 40, 55), (170, 55, 35)),
            ((65, 75, 90), (150, 155, 165), (35, 45, 60), (210, 125, 40)),
            ((70, 50, 55), (160, 75, 55), (45, 30, 40), (235, 155, 55)),
            ((50, 65, 70), (105, 145, 145), (25, 45, 50), (80, 210, 180)),
            ((75, 75, 80), (165, 165, 160), (40, 45, 50), (220, 190, 95)),
            ((60, 55, 75), (125, 100, 155), (35, 30, 50), (220, 65, 75)),
            ((55, 70, 55), (125, 155, 95), (30, 45, 35), (210, 185, 70)),
            ((70, 60, 50), (160, 130, 95), (40, 35, 30), (230, 105, 40)),
            ((55, 65, 80), (115, 145, 180), (25, 35, 55), (90, 175, 225)),
            ((75, 55, 60), (165, 105, 100), (45, 30, 40), (230, 80, 55)),
            ((60, 70, 70), (145, 155, 145), (35, 45, 45), (200, 200, 140)),
            ((75, 65, 50), (155, 135, 85), (45, 35, 25), (220, 150, 45)),
            ((65, 65, 70), (145, 145, 150), (35, 35, 40), (225, 100, 45)),
            ((45, 60, 70), (100, 155, 175), (25, 40, 55), (60, 220, 220)),
            ((65, 35, 45), (185, 65, 50), (35, 20, 30), (255, 185, 45)),
        ][theme % 15]
        base, mortar, deep, accent = (_c(c) for c in palette)
        image = Image.new("L", (64, 64), base if not shade else deep)
        draw = ImageDraw.Draw(image)
        if theme == 13:
            draw.rectangle((5, 4, 58, 59), outline=mortar, width=4)
            draw.rectangle((12, 12, 51, 55), fill=deep, outline=accent, width=3)
            for y in range(17, 53, 9):
                draw.line((17, y, 46, y), fill=accent if y == 35 else mortar, width=2)
            draw.rectangle((27, 8, 36, 59), fill=accent)
        elif theme == 14:
            draw.rectangle((4, 4, 59, 59), outline=accent, width=4)
            draw.rectangle((10, 10, 53, 53), fill=deep, outline=mortar, width=3)
            draw.polygon([(32, 14), (47, 31), (32, 48), (17, 31)], outline=accent, fill=base)
            draw.ellipse((27, 26, 37, 36), fill=accent)
        elif theme % 3 == 0:
            for y in range(-2, 66, 16):
                shift = 0 if (y // 16) & 1 else 12
                for x in range(-12 + shift, 68, 24):
                    draw.rectangle((x + 1, y + 1, x + 21, y + 13), outline=mortar, width=2)
                    draw.line((x + 4, y + 3, x + 18, y + 3), fill=accent if (x + y) % 5 == 0 else base)
        elif theme % 3 == 1:
            draw.rectangle((5, 5, 58, 58), outline=mortar, width=3)
            for x in (14, 32, 50):
                draw.line((x, 7, x, 56), fill=accent if x == 32 else mortar, width=2)
            for y in (16, 32, 48):
                draw.line((7, y, 56, y), fill=mortar, width=2)
            for x, y in ((10, 10), (53, 10), (10, 53), (53, 53)):
                draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=accent)
        else:
            draw.polygon([(32, 3), (60, 32), (32, 60), (3, 32)], outline=mortar, width=3)
            draw.polygon([(32, 14), (49, 32), (32, 49), (14, 32)], outline=accent, width=2)
            draw.line((8, 32, 56, 32), fill=base, width=2)
        return [[image.getpixel((x, y)) for x in range(64)] for y in range(64)]

    def sprite(self, n):
        if n in (416, 418, 421, 423, 426, 428, 431, 433):
            image, draw = _sprite_base()
            steel, shade, glow = _c((155, 165, 175)), _c((45, 50, 65)), _c((245, 105, 45))
            draw.polygon([(25, 63), (28, 49), (28, 36), (31, 31), (35, 31), (38, 37), (38, 50), (42, 63)], fill=shade)
            draw.rectangle((27, 39, 37, 47), fill=steel)
            draw.rectangle((29, 25, 35, 39), fill=steel)
            draw.rectangle((30, 18, 34, 31), fill=glow if n in (418, 423, 428, 433) else shade)
            draw.line((31, 19, 31, 29), fill=steel, width=2)
            return _grid(image)

        image, draw = _sprite_base()
        if n in (50, 58, 66, 74, 82, 96, 97, 98, 90, 91, 92, 93, 95):
            armor = _c((85, 105, 125) if n not in (96, 97, 98, 90, 91, 92, 93, 95) else (100, 65, 75))
            bright, shadow = _c((175, 185, 185)), _c((35, 40, 55))
            blood, eye = _c((185, 40, 35)), _c((255, 170, 45))
            draw.polygon([(17, 38), (23, 29), (41, 29), (48, 39), (45, 52), (40, 59), (24, 59), (19, 51)], fill=armor)
            draw.rectangle((23, 16, 41, 34), fill=shadow)
            draw.polygon([(22, 17), (27, 8), (38, 8), (43, 18), (40, 27), (24, 27)], fill=bright)
            draw.rectangle((24, 19, 40, 23), fill=shadow)
            draw.rectangle((27, 20, 30, 22), fill=eye)
            draw.rectangle((35, 20, 38, 22), fill=eye)
            draw.rectangle((27, 30, 37, 34), fill=blood if n % 3 == 0 else shadow)
            draw.polygon([(17, 37), (10, 43), (14, 52), (21, 48)], fill=shadow)
            draw.polygon([(44, 37), (52, 43), (49, 51), (43, 48)], fill=bright)
            draw.polygon([(24, 53), (31, 53), (29, 63), (20, 63)], fill=shadow)
            draw.polygon([(35, 53), (42, 53), (45, 63), (34, 63)], fill=shadow)
            if n in (66, 74, 82):
                draw.rectangle((14, 42, 18, 47), fill=blood)
            return _grid(image)

        item = max(0, n - 2)
        base = [_c((65, 190, 95)), _c((220, 175, 55)), _c((90, 180, 225)), _c((205, 70, 55))][item % 4]
        dark = _c((35, 45, 55))
        if item % 5 == 0:
            draw.rectangle((16, 29, 48, 57), fill=dark, outline=base, width=3)
            draw.rectangle((21, 34, 43, 51), fill=base)
            draw.line((23, 38, 40, 38), fill=_c((240, 230, 170)), width=2)
        elif item % 5 == 1:
            draw.polygon([(32, 7), (49, 32), (32, 57), (15, 32)], fill=base, outline=_c((245, 215, 110)))
            draw.line((32, 12, 32, 52), fill=_c((245, 245, 220)), width=2)
        elif item % 5 == 2:
            draw.rectangle((15, 27, 49, 54), fill=dark, outline=base, width=3)
            draw.rectangle((21, 33, 43, 48), fill=base)
            draw.rectangle((26, 23, 38, 30), fill=_c((175, 185, 185)))
        elif item % 5 == 3:
            draw.ellipse((15, 17, 49, 54), fill=dark, outline=base, width=4)
            draw.ellipse((25, 27, 39, 42), fill=_c((245, 120, 45)))
        else:
            draw.polygon([(18, 52), (22, 25), (32, 13), (42, 25), (46, 52)], fill=base, outline=dark)
            draw.rectangle((28, 27, 36, 44), fill=_c((245, 225, 145)))
        return _grid(image)


class VgaGraph:
    def pic(self, n):
        if n == 95:
            width, height = 320, 40
        elif n in (105, 106, 107, *range(108, 118)):
            width, height = 8, 16
        elif n in (100, 101, 102, 103):
            width, height = 48, 24
        else:
            width, height = 24, 32
        image = Image.new("L", (width, height), _c((12, 18, 28)))
        draw = ImageDraw.Draw(image)
        font = ImageFont.load_default()
        steel, glow = _c((125, 145, 160)), _c((220, 100, 45))
        if n == 95:
            draw.rectangle((0, 0, width - 1, height - 1), fill=_c((15, 28, 42)), outline=steel, width=2)
            for x in (96, 160, 222):
                draw.line((x, 4, x, 35), fill=steel, width=2)
            for x, label in ((9, "SECTOR"), (101, "SCORE"), (166, "VITAL"), (230, "CELLS")):
                draw.text((x, 4), label, fill=glow, font=font)
            for x in (9, 101, 166, 230):
                draw.line((x, 17, x + 51, 17), fill=steel)
        elif n in (107, *range(108, 118)):
            digit = "" if n == 107 else str((n - 108) % 10)
            draw.text((1, 1), digit, fill=glow, font=font)
        elif n in (105, 106):
            draw.polygon([(1, 8), (4, 2), (7, 8), (4, 14)], fill=glow if n == 105 else steel)
            draw.line((4, 4, 4, 11), fill=_c((255, 220, 110)))
        elif n in (100, 101, 102, 103):
            draw.rectangle((4, 5, 43, 21), fill=_c((30, 40, 55)), outline=steel, width=2)
            draw.rectangle((18, 1, 29, 12), fill=glow if n % 2 else steel)
            draw.line((8, 16, 39, 16), fill=glow)
        else:
            draw.ellipse((3, 1, 20, 20), fill=_c((130, 85, 55)), outline=steel, width=2)
            draw.rectangle((6, 8, 9, 10), fill=glow)
            draw.rectangle((14, 8, 17, 10), fill=glow)
            draw.rectangle((7, 13, 17, 16), fill=_c((55, 35, 40)))
            draw.rectangle((2, 21, 21, 31), fill=_c((55, 70, 85)), outline=steel)
        return width, height, [[image.getpixel((x, y)) for x in range(width)] for y in range(height)]


def load_map(_level=0):
    p0 = [1] * (64 * 64)
    p1 = [0] * (64 * 64)
    def put(x, y, tile):
        p0[y * 64 + x] = tile

    for y in range(11, 53):
        for x in range(11, 53):
            put(x, y, 0)

    for y in range(8, 56):
        if y not in range(17, 21) and y not in range(39, 43):
            put(23, y, 4 if y % 4 else 5)
        if y not in range(28, 32):
            put(40, y, 7 if y % 3 else 8)
    for x in range(8, 56):
        if x not in range(13, 17) and x not in range(47, 51):
            put(x, 34, 2 if x % 2 else 3)
    put(23, 18, 90)
    put(40, 30, 91)
    put(50, 48, 21)

    p1[14 * 64 + 14] = 20
    p1[14 * 64 + 18] = 108
    p1[12 * 64 + 20] = 23 + 1
    p1[16 * 64 + 30] = 23 + 6
    p1[24 * 64 + 35] = 23 + 20
    p1[31 * 64 + 46] = 23 + 29
    return "ASHEN BASTION", 64, 64, p0, p1
