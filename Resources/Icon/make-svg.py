#!/usr/bin/env python3
"""한라봉 로고(B1: 자른 단면 8조각 = 휠 8칸) SVG를 만든다.
   hanlabong-appicon.svg  앱 아이콘 원본(꽉 찬 사각, macOS가 모서리를 둥글린다)
   hanlabong-mark.svg     바탕 없는 로고(사이트·README용)
   hanlabong-template.svg 흑백 한 색(메뉴바 모양 참고용)"""
import math, os
HERE = os.path.dirname(os.path.abspath(__file__))

def rounded_wedge(cx, cy, r0, r1, mid, gap, rc):
    """둥근 조각: 옆 변은 gap/2 만큼 평행하게 띄우고, rc 만큼 줄인 뒤 같은 색 선으로 둘러 모서리를 둥글린다."""
    s, a, m = gap / 2 + rc, math.radians(22.5), math.radians(mid - 90)
    def side(sign):
        phi = m + sign * a
        nx, ny = math.sin(phi) * sign, -math.cos(phi) * sign
        def at(r):
            t = math.sqrt(max(r * r - s * s, 0))
            return f"{cx + s * nx + t * math.cos(phi):.2f} {cy + s * ny + t * math.sin(phi):.2f}"
        return at
    L, R = side(-1), side(1)
    ri, ro = max(r0 + rc, s / math.sin(a) * 1.08), r1 - rc
    return f"M{L(ri)} L{L(ro)} A{ro:.2f} {ro:.2f} 0 0 1 {R(ro)} L{R(ri)} A{ri:.2f} {ri:.2f} 0 0 0 {L(ri)}Z"

def wedges(fill, sel, cx=100, cy=100, r0=9, r1=55, gap=7, rc=4):
    out = []
    for i in range(8):
        f = sel if i == 0 else fill
        out.append(f'<path d="{rounded_wedge(cx, cy, r0, r1, i * 45, gap, rc)}" fill="{f}" stroke="{f}" stroke-width="{rc * 2}" stroke-linejoin="round"/>')
    return "".join(out)

DEFS = """<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff7ec"/><stop offset="1" stop-color="#ffdcbc"/></linearGradient>
<linearGradient id="peel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff9d3a"/><stop offset="1" stop-color="#e85c00"/></linearGradient>
<radialGradient id="flesh" cx="100" cy="100" r="60" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#ffc25e"/><stop offset="1" stop-color="#ff8f24"/></radialGradient>
<linearGradient id="sel" x1="0" y1="45" x2="0" y2="95" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff0c8"/><stop offset="1" stop-color="#ffb347"/></linearGradient>
</defs>"""

FRUIT = ('<circle cx="100" cy="100" r="68" fill="url(#peel)"/>'
         '<circle cx="100" cy="100" r="61" fill="#fff3e2"/>'
         + wedges("url(#flesh)", "url(#sel)") +
         '<path d="M52 64 A60 60 0 0 1 112 33" stroke="#fff" stroke-opacity=".5" stroke-width="5" fill="none" stroke-linecap="round"/>')

def svg(body, vb="0 0 200 200"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="1024" height="1024">{DEFS}{body}</svg>\n'

def write(name, text):
    with open(os.path.join(HERE, name), "w", encoding="utf-8") as f:
        f.write(text)

# 앱 아이콘: 바탕을 꽉 채우고 과일을 조금 키운다
write("hanlabong-appicon.svg", svg('<rect width="200" height="200" fill="url(#bg)"/><g transform="translate(100 100) scale(1.08) translate(-100 -100)">' + FRUIT + '</g>'))
write("hanlabong-mark.svg", svg(FRUIT, "30 30 140 140"))
mono = ('<circle cx="100" cy="100" r="64.5" fill="none" stroke="#000" stroke-width="7"/>'
        + wedges("#000", "#000", r0=10, r1=54, gap=9, rc=4))
write("hanlabong-template.svg", svg(mono, "30 30 140 140"))
print("ok")

# 링크 공유 썸네일(카톡·블로그·SNS): 1200×630
og = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">{DEFS}'
      '<rect width="1200" height="630" fill="url(#bg)"/>'
      '<g transform="translate(110 115) scale(2)">' + FRUIT + '</g>'
      '<text x="600" y="285" font-family="Apple SD Gothic Neo" font-weight="800" font-size="104" fill="#2a2420">한라봉</text>'
      '<text x="604" y="360" font-family="Apple SD Gothic Neo" font-weight="600" font-size="40" fill="#e85d00">끌고, 누르고, 놓으면 끝.</text>'
      '<text x="604" y="420" font-family="Apple SD Gothic Neo" font-size="30" fill="#7a6f66">맥에서 파일을 끌다가 키 하나로 바꾸는 앱</text>'
      '</svg>\n')
write("hanlabong-og.svg", og)

# 애드온 아이콘: 같은 한라봉 단면에 작은 표시를 붙여 한 가족으로
#   Developing: 어두운 바탕(사진 보는 방) + 조리개
#   PDF: 크림 바탕 + 문서
DARK = '<linearGradient id="dark" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#3a332d"/><stop offset="1" stop-color="#15120f"/></linearGradient>'
def badge_icon(background, badge):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="1024" height="1024">{DEFS.replace("</defs>", DARK + "</defs>")}'
            f'<rect width="200" height="200" fill="{background}"/>'
            '<g transform="translate(88 88) scale(0.9) translate(-100 -100)">' + FRUIT + '</g>' + badge + '</svg>\n')

def aperture(cx, cy, r):
    blades = "".join(
        f'<line x1="{cx + r * 0.95 * math.cos(math.radians(a)):.1f}" y1="{cy + r * 0.95 * math.sin(math.radians(a)):.1f}" '
        f'x2="{cx + r * 0.35 * math.cos(math.radians(a + 70)):.1f}" y2="{cy + r * 0.35 * math.sin(math.radians(a + 70)):.1f}" '
        'stroke="#ffb347" stroke-width="5" stroke-linecap="round"/>' for a in range(0, 360, 60))
    return f'<circle cx="{cx}" cy="{cy}" r="{r + 6}" fill="#1c1916"/><circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#ffb347" stroke-width="6"/>' + blades

DOC = ('<g transform="translate(132 120)"><rect x="0" y="0" width="54" height="66" rx="9" fill="#fff" stroke="#e85d00" stroke-width="6"/>'
       '<g stroke="#e85d00" stroke-width="5" stroke-linecap="round"><line x1="13" y1="20" x2="41" y2="20"/><line x1="13" y1="34" x2="41" y2="34"/><line x1="13" y1="48" x2="31" y2="48"/></g></g>')

write("developing-appicon.svg", badge_icon("url(#dark)", aperture(156, 156, 28)))
write("pdf-appicon.svg", badge_icon("url(#bg)", DOC))
