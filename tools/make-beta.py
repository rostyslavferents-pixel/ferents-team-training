#!/usr/bin/env python3
"""Робить пробну копію beta/index.html з index.html.
Код той самий; копія сама вмикає новий вигляд, бо лежить у папці /beta/.
Відрізняються лише шляхи до спільних файлів (іконки, шрифт, маніфест)."""
import pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent
s = (root / 'index.html').read_text(encoding='utf8')
# Список файлів для резервної копії вже має префікс ROOTP — його не чіпаємо
a = s.index("const own = ['index.html'"); b = s.index('];', a)
own = s[a:b]
s = re.sub(r'(["\'(])(icons|fonts)/', r'\1../\2/', s[:a]) + own + re.sub(r'(["\'(])(icons|fonts)/', r'\1../\2/', s[b:])
s = s.replace('href="manifest.webmanifest"', 'href="../manifest.webmanifest"')
s = s.replace("navigator.serviceWorker.register('sw.js')", "navigator.serviceWorker.register('../sw.js', { scope: '../' })")
(root / 'beta').mkdir(exist_ok=True)
(root / 'beta' / 'index.html').write_text(s, encoding='utf8')
print('beta/index.html готово')
