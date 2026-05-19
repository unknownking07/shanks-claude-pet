#!/usr/bin/env python3
"""
Generate Shanks pixel-art sprites for Shanks.app.

Chibi proportions: big head, small body. At 32x32, the head dominates so the face is
readable. Hair flows down the sides; scar is a diagonal slash over the right eye
(Shanks's left, his canonical scar side).

Outputs (32x32 native, scaled 10x with nearest-neighbor):
  Clawd/ShanksSheet.png       2880x320 sheet, 9 frames horizontal
  Clawd/ShanksAsleep1.png     320x320
  Clawd/ShanksAsleep2.png     320x320
  Clawd/ShanksIcon.png        320x320 (icon)

Sheet frame order (matches CatSpriteRenderer.swift):
  0 idle, 1 walkA, 2 walkB, 3 blink, 4 sad, 5 happy, 6 surprised, 7 smug, 8 sleepy
"""
from PIL import Image
from pathlib import Path

W, H = 32, 32
SCALE = 10
OUT_DIR = Path(__file__).resolve().parent.parent / "Clawd"

PALETTE = {
    '.': None,
    'R': (200, 40, 40, 255),
    'D': (130, 20, 20, 255),
    'S': (245, 205, 165, 255),
    'F': (210, 165, 120, 255),
    'K': (35, 28, 28, 255),
    'X': (135, 25, 20, 255),
    'W': (245, 240, 230, 255),
    'C': (190, 185, 175, 255),
    'B': (115, 70, 35, 255),
    'b': (75, 45, 20, 255),
    'N': (45, 55, 80, 255),
    'M': (160, 65, 55, 255),
    'm': (210, 90, 80, 255),
    'G': (225, 175, 60, 255),
    'g': (170, 120, 30, 255),
    'z': (140, 175, 220, 255),
    'Z': (105, 145, 200, 255),
    'O': (250, 245, 235, 255),
}


def make_frame(rows):
    if len(rows) != H:
        raise ValueError(f"expected {H} rows, got {len(rows)}")
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    for y, row in enumerate(rows):
        if len(row) != W:
            raise ValueError(f"row {y} length {len(row)} (need {W}): {row!r}")
        for x, ch in enumerate(row):
            color = PALETTE.get(ch)
            if color is not None:
                px[x, y] = color
    return img


def scale(img, factor=SCALE):
    return img.resize((img.width * factor, img.height * factor), Image.NEAREST)


def body_standing():
    return [
        "...........SSSSSSSS.............",  # 16 neck
        "..........bBBBBBBBBb............",  # 17 cape collar
        ".........bBBWWWWWWBBb...........",  # 18 shoulders
        ".........BWWWWWWWWWWB...........",  # 19 chest
        ".........BWWGGGGGGGWB...........",  # 20 sash
        ".........BWWGGGGGGGWB...........",  # 21 sash
        ".........BWWWWgggggWB...........",  # 22 sash shadow
        ".........bBNNNNNNNNBb...........",  # 23 belt
        "..........NNNNNNNNNN............",  # 24 hips
        "..........NNNN..NNNN............",  # 25 legs split
        "..........NNNN..NNNN............",  # 26
        "..........BBBB..BBBB............",  # 27 boots
        "..........KKKK..KKKK............",  # 28 soles
        "................................",  # 29
        "................................",  # 30
        "................................",  # 31
    ]


def body_walk_a():
    return [
        "...........SSSSSSSS.............",
        "..........bBBBBBBBBb............",
        ".........bBBWWWWWWBBb...........",
        ".........BWWWWWWWWWWB...........",
        ".........BWWGGGGGGGWB...........",
        ".........BWWGGGGGGGWB...........",
        ".........BWWWWgggggWB...........",
        ".........bBNNNNNNNNBb...........",
        "..........NNNNNNNNNN............",
        "..........NNNNN.NNN.............",
        "..........NNNNN.NNN.............",
        "..........BBBBB.BBB.............",
        "..........KKKKK.KKK.............",
        "................................",
        "................................",
        "................................",
    ]


def body_walk_b():
    return [
        "...........SSSSSSSS.............",
        "..........bBBBBBBBBb............",
        ".........bBBWWWWWWBBb...........",
        ".........BWWWWWWWWWWB...........",
        ".........BWWGGGGGGGWB...........",
        ".........BWWGGGGGGGWB...........",
        ".........BWWWWgggggWB...........",
        ".........bBNNNNNNNNBb...........",
        "..........NNNNNNNNNN............",
        "..........NNN.NNNNN.............",
        "..........NNN.NNNNN.............",
        "..........BBB.BBBBB.............",
        "..........KKK.KKKKK.............",
        "................................",
        "................................",
        "................................",
    ]


# HEAD: rows 0..15 (16 rows). Big chibi head, flowing red hair, scar diagonal over the
# right eye area (cols 17-20 across rows 7-10). Eyes at cols 12-13 (left) and cols 18-19
# (right). Mouth at rows 12-13 cols 14-17.
HEAD_IDLE = [
    "................................",  # 0
    "............RRRRRR..............",  # 1
    "..........RRDDDDDDRR............",  # 2
    ".........RDDRRRRRRDDR...........",  # 3
    "........RDDRRRRRRRRDDR..........",  # 4
    "........RDRRSSSSSSRRDR..........",  # 5
    ".......RDDRSSSSSSXXRDDR.........",  # 6 scar top
    ".......RDRSSSSSSSXXSDDR.........",  # 7
    ".......RDRSSSSSSXXSSSDR.........",  # 8
    ".......RDSSKKSSXXSSKKSDR........",  # 9 - eyes; scar crosses right eye
    ".......RDSSKKSSXSSSKKSDR........",  # 10
    ".......RDSSSSSSSSSSSSDR.........",  # 11
    "........RSSSSSMMMMSSSR..........",  # 12
    "........RRSSSSSmmmSSRR..........",  # 13
    ".........RRSSSSSSSRR............",  # 14
    "..........RRSSSSRR..............",  # 15
]


def face_variant(ops):
    rows = list(HEAD_IDLE)
    for r, new in ops.items():
        if len(new) != W:
            raise ValueError(f"row {r}: len {len(new)} != {W}: {new!r}")
        rows[r] = new
    return rows


FRAMES = {}
FRAMES["idle"] = HEAD_IDLE + body_standing()
FRAMES["walkA"] = HEAD_IDLE + body_walk_a()
FRAMES["walkB"] = HEAD_IDLE + body_walk_b()

FRAMES["blink"] = face_variant({
    9:  ".......RDSSKKKSSXXSKKKSDR.......",
    10: ".......RDSSSSSSXSSSSSSDR........",
}) + body_standing()

FRAMES["sad"] = face_variant({
    9:  ".......RDSSSSSSXXSSSSSDR........",
    10: ".......RDSSKKSSXSSSKKSDR........",
    12: "........RSSSSmmmmSSSSR..........",
    13: "........RRSSMMMMMMSSRR..........",
}) + body_standing()

FRAMES["happy"] = face_variant({
    9:  ".......RDSSKKSSXXSSKKSDR........",
    10: ".......RDSSSKSSXSSSKSSDR........",
    12: "........RSSMMMOOMMMSR...........",
    13: "........RRSMMMMMMSSRR...........",
}) + body_standing()

FRAMES["surprised"] = face_variant({
    8:  ".......RDRSSKKSXXSSKKSDR........",
    9:  ".......RDSSKKSSXXSSKKSDR........",
    10: ".......RDSSKKSSXSSSKKSDR........",
    12: "........RSSSSMMMMSSSSR..........",
    13: "........RRSSSKKKKSSSRR..........",
}) + body_standing()

FRAMES["smug"] = face_variant({
    9:  ".......RDSSKKSSXXSSKKSDR........",
    10: ".......RDSSSSSSXSSSSKKSDR........"[:32],
    12: "........RSSSSSMMMMmSR...........",
    13: "........RRSSSSSmmmSRR...........",
}) + body_standing()

FRAMES["scared"] = face_variant({
    9:  ".......RDSSSKSSXXSSSKSDR........",
    10: ".......RDSSSSSSXSSSSSSDR........",
    12: "........RSSSMmMmMmSSR...........",
    13: "........RRSSSSSSSSSRR...........",
}) + body_standing()

FRAMES["sleepy"] = face_variant({
    9:  ".......RDSSKKSSXXSSKKSDR........",
    10: ".......RDSSSSSSXSSSSSSDR........",
    12: "........RSSSSSMMSSSSSR..........",
    13: "........RRSSSSSSSSSRR...........",
}) + body_standing()


SHEET_ORDER = ["idle", "walkA", "walkB", "blink", "sad", "happy", "surprised", "smug", "sleepy"]


def build_sheet():
    frames = [make_frame(FRAMES[name]) for name in SHEET_ORDER]
    scaled = [scale(f) for f in frames]
    sheet = Image.new("RGBA", (scaled[0].width * len(scaled), scaled[0].height), (0, 0, 0, 0))
    for i, f in enumerate(scaled):
        sheet.paste(f, (i * f.width, 0))
    return sheet


ASLEEP_1 = [
    "................................",  # 0
    "................................",  # 1
    "................................",  # 2
    "................................",  # 3
    "................................",  # 4
    "................................",  # 5
    "....z...........................",  # 6
    "...z............................",  # 7
    "..zz............................",  # 8
    "...z.........RRRRRR.............",  # 9
    "...........RRDDDDDDRR...........",  # 10
    "..........RDDRRRRRRDDR..........",  # 11
    "..........RDRSSSSSSRDR..........",  # 12
    "..........RDSSSSSSSSDR..........",  # 13
    "..........RDSSKKSXXSKKDR........",  # 14 scar over right eye
    "..........RDSSSSSXSSSDR.........",  # 15
    "..........RDSSSMMMSSSDR.........",  # 16
    "...........RSSSSSSSR............",  # 17
    "...........bBBBBBBBb............",  # 18
    "..........bBBWWWWWWBBb..........",  # 19
    "..........BWWWWWWWWWWB..........",  # 20
    "..........BWWGGGGGGGWB..........",  # 21
    "..........BWWGGGGGGGWB..........",  # 22
    "..........BWWWWWWWWWWB..........",  # 23
    "..........bBNNNNNNNNBb..........",  # 24
    "...........NNNNNNNNN............",  # 25
    "...........NN....NN.............",  # 26
    "...........NN....NN.............",  # 27
    "...........BB....BB.............",  # 28
    "...........KK....KK.............",  # 29
    "................................",  # 30
    "................................",  # 31
]

ASLEEP_2 = [
    "................................",  # 0
    "................................",  # 1
    "................................",  # 2
    "................................",  # 3
    "...Z............................",  # 4
    "..Z.Z...........................",  # 5
    "....Z...........................",  # 6
    "...Z............................",  # 7
    "..ZZZZ..........................",  # 8
    ".............RRRRRR.............",  # 9
    "...........RRDDDDDDRR...........",  # 10
    "..........RDDRRRRRRDDR..........",  # 11
    "..........RDRSSSSSSRDR..........",  # 12
    "..........RDSSSSSSSSDR..........",  # 13
    "..........RDSSKKSXXSKKDR........",  # 14
    "..........RDSSSSSXSSSDR.........",  # 15
    "..........RDSSSMmmSSSDR.........",  # 16
    "...........RSSSSSSSR............",  # 17
    "...........bBBBBBBBb............",  # 18
    "..........bBBWWWWWWBBb..........",  # 19
    "..........BWWWWWWWWWWB..........",  # 20
    "..........BWWGGGGGGGWB..........",  # 21
    "..........BWWGGGGGGGWB..........",  # 22
    "..........BWWWWWWWWWWB..........",  # 23
    "..........bBNNNNNNNNBb..........",  # 24
    "...........NNNNNNNNN............",  # 25
    "...........NN....NN.............",  # 26
    "...........NN....NN.............",  # 27
    "...........BB....BB.............",  # 28
    "...........KK....KK.............",  # 29
    "................................",  # 30
    "................................",  # 31
]


ICON = [
    "................................",  # 0
    ".........RRRRRRRRRRRR...........",  # 1
    "........RDDDDDDDDDDDDR..........",  # 2
    ".......RDDDRRRRRRRRDDDR.........",  # 3
    "......RDDRRRRRRRRRRRRDDR........",  # 4
    "......RDRRSSSSSSSSSSRRDR........",  # 5
    ".....RDDRSSSSSSSSXXRRDDR........",  # 6 scar starts
    ".....RDRSSSSSSSSSXXSRRDR........",  # 7
    ".....RDRSSSSSSSSXXSSSRDR........",  # 8
    ".....RDRSSKKKSSXXSSKKKDR........",  # 9 eyes; scar through right eye
    ".....RDRSSKKKSSXSSSKKKSDR.......",  # 10
    ".....RDRSSSSSSSSSSSSSSSDR.......",  # 11
    "......RDSSSSSSSSSSSSSSDR........",  # 12
    "......RDSSSSMMMMMMMMSSDR........",  # 13
    "......RDDSSSSMMmmmmMSSDDR.......",  # 14
    ".......RDSSSSSSSSSSSSDR.........",  # 15
    "........RRSSSSSSSSSSRR..........",  # 16
    ".........RRSSSSSSSSRR...........",  # 17
    "...........SSSSSSSS.............",  # 18
    "..........bBBBBBBBBb............",  # 19
    ".........bBBWWWWWWBBb...........",  # 20
    ".........BWWWWWWWWWWB...........",  # 21
    ".........BWWGGGGGGGWB...........",  # 22
    ".........BWWGGGGGGGWB...........",  # 23
    ".........BWWWWWWWWWWB...........",  # 24
    ".........bBBBBBBBBBBb...........",  # 25
    "................................",  # 26
    "................................",  # 27
    "................................",  # 28
    "................................",  # 29
    "................................",  # 30
    "................................",  # 31
]


def main():
    print(f"Output dir: {OUT_DIR}")
    sheet = build_sheet()
    sheet_path = OUT_DIR / "ShanksSheet.png"
    sheet.save(sheet_path)
    print(f"  ✓ {sheet_path}  ({sheet.size[0]}x{sheet.size[1]})")

    for name, rows in [("ShanksAsleep1", ASLEEP_1), ("ShanksAsleep2", ASLEEP_2), ("ShanksIcon", ICON)]:
        img = scale(make_frame(rows))
        p = OUT_DIR / f"{name}.png"
        img.save(p)
        print(f"  ✓ {p}  ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()
