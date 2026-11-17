from PIL import Image, ImageDraw, ImageFont
import glob, os
L='/Users/duegin/Documents/inputAppLock/assets/logo'
F=ImageFont.truetype('/System/Library/Fonts/Hiragino Sans GB.ttc',16)
bad=0
for f in sorted(glob.glob(L+'/menubar/*.png')):
    im=Image.open(f).convert('RGBA'); px=list(im.getdata())
    nb=sum(1 for p in px if p[3]>0 and p[:3]!=(0,0,0)); bad+=nb
    print(os.path.basename(f), im.size, 'non-black visible px:', nb)
print('ALL PURE BLACK' if bad==0 else 'NOT PURE BLACK')
states=[('','锁定'),('Secure','密码框英文模式'),('Disabled','未启用')]
im=Image.new('RGB',(1180,560),'#f6f6f3'); dr=ImageDraw.Draw(im)
dr.text((20,12),'菜单栏三态 · 18pt template：@1x ×8 / @2x ×4 / 浅色、深色菜单栏实际尺寸（三态并排）/ 16px 缩放',font=F,fill='#111')
def tm(p,c):
    a=Image.open(p).convert('RGBA').split()[3]; o=Image.new('RGBA',a.size,c); o.putalpha(a); return o
for i,(s,n) in enumerate(states):
    x=20+i*390
    dr.text((x,44),f'MenuBarIcon{s}Template — {n}',font=F,fill='#333')
    for j,tag in enumerate(('','@2x')):
        t=tm(f'{L}/menubar/MenuBarIcon{s}Template{tag}.png',(0,0,0,255)); b=Image.new('RGBA',t.size,'white'); b.alpha_composite(t)
        im.paste(b.resize((144,144),Image.NEAREST),(x+j*160,74))
    t=tm(f'{L}/menubar/MenuBarIcon{s}Template@2x.png',(0,0,0,255)).resize((16,16),Image.LANCZOS)
    b=Image.new('RGBA',(16,16),'white'); b.alpha_composite(t); im.paste(b,(x,240)); im.paste(b.resize((96,96),Image.NEAREST),(x+40,240))
for j,(bg,fg) in enumerate((('#ececec',(30,30,30,255)),('#2a2a2c',(240,240,240,255)))):
    for k,tag in enumerate(('','@2x')):
        sz=18 if tag=='' else 36
        bar=Image.new('RGBA',(sz*8,sz+12),bg)
        for q,(ss,_) in enumerate(states):
            bar.alpha_composite(tm(f'{L}/menubar/MenuBarIcon{ss}Template{tag}.png',fg),(sz//2+q*sz*2,6))
        im.paste(bar,(20+k*420,370+j*90))
im.save(L+'/tests/menubar-states-test.png')
