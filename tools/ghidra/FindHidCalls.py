# Ghidra post-analysis script (Jython / Python 2).
# Задача: найти все вызовы HidD_SetOutputReport / HidD_SetFeature и
# декомпилировать вызывающие функции, чтобы восстановить байтовый формат
# пакета подсветки. Результат печатается в stdout (его собирает analyzeHeadless).
# Запускается через: analyzeHeadless ... -postScript FindHidCalls.py

from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

# Интересующие нас Windows HID API функции отправки отчётов в устройство.
TARGETS = [
    "HidD_SetOutputReport",
    "HidD_SetFeature",
    "WriteFile",            # часто отчёт шлётся через WriteFile по HID-хэндлу
    "HidD_GetFeature",
]

fm = currentProgram.getFunctionManager()
st = currentProgram.getSymbolTable()
ref_mgr = currentProgram.getReferenceManager()

# Готовим декомпилятор.
decomp = DecompInterface()
decomp.openProgram(currentProgram)
monitor = ConsoleTaskMonitor()

def decompile(func):
    # Возвращает C-псевдокод функции или None.
    res = decomp.decompileFunction(func, 60, monitor)
    if res and res.decompileCompleted():
        return res.getDecompiledFunction().getC()
    return None

# Собираем адреса символов-мишеней (импортов).
printed = set()
for name in TARGETS:
    syms = st.getGlobalSymbols(name)
    for sym in syms:
        addr = sym.getAddress()
        print("\n==== TARGET %s @ %s ====" % (name, addr))
        # Все ссылки НА этот символ = места вызова.
        refs = ref_mgr.getReferencesTo(addr)
        callers = set()
        for r in refs:
            fn = fm.getFunctionContaining(r.getFromAddress())
            if fn is not None:
                callers.add(fn)
        for fn in callers:
            key = fn.getEntryPoint().toString()
            if key in printed:
                continue
            printed.add(key)
            print("\n---- caller: %s @ %s ----" % (fn.getName(), key))
            c = decompile(fn)
            if c:
                print(c)
            else:
                print("(decompile failed)")

print("\n==== DONE, callers printed: %d ====" % len(printed))
