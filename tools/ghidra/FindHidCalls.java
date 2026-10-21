// Ghidra post-analysis script (Java).
// Находит вызовы HID-функций отправки отчётов и декомпилирует вызывающие
// функции, чтобы восстановить байтовый формат пакета подсветки.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolTable;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.address.Address;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class FindHidCalls extends GhidraScript {
    // Интересующие HID API (подстроки имён).
    static final String[] TARGETS = {
        "HidD_SetOutputReport", "HidD_SetFeature", "HidD_GetFeature", "WriteFile"
    };

    boolean matches(String n) {
        for (String t : TARGETS) if (n != null && n.contains(t)) return true;
        return false;
    }

    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        SymbolTable st = currentProgram.getSymbolTable();
        ReferenceManager rm = currentProgram.getReferenceManager();
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // 1) Диагностика: все символы, похожие на HID/WriteFile.
        println("==== matching symbols ====");
        Set<Address> targetAddrs = new HashSet<Address>();
        SymbolIterator it = st.getAllSymbols(true);
        while (it.hasNext()) {
            Symbol s = it.next();
            if (matches(s.getName())) {
                println("sym: " + s.getName() + " @ " + s.getAddress() + " type=" + s.getSymbolType()
                        + " ext=" + s.isExternal());
                targetAddrs.add(s.getAddress());
            }
        }

        // 2) Собираем вызывающие функции: ссылки на адреса символов + callers thunk-функций.
        Set<Function> callers = new HashSet<Function>();
        for (Address a : targetAddrs) {
            for (Reference r : rm.getReferencesTo(a)) {
                Function fn = fm.getFunctionContaining(r.getFromAddress());
                if (fn != null) callers.add(fn);
            }
        }
        // thunk-функции с нужным именем → их вызывающие.
        for (Function f : fm.getFunctions(true)) {
            if (matches(f.getName())) {
                for (Function c : f.getCallingFunctions(mon)) callers.add(c);
            }
        }

        println("\n==== callers: " + callers.size() + " ====");
        Set<String> printed = new HashSet<String>();
        for (Function fn : callers) {
            String key = fn.getEntryPoint().toString();
            if (!printed.add(key)) continue;
            println("\n---- caller: " + fn.getName() + " @ " + key + " ----");
            DecompileResults res = decomp.decompileFunction(fn, 60, mon);
            if (res != null && res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
            } else {
                println("(decompile failed)");
            }
        }
        println("\n==== DONE ====");
    }
}
