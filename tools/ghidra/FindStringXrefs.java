// Ghidra script (Java): находит строки-ключи настроек подсветки и
// декомпилирует функции, которые на них ссылаются (парсер/сериализатор JSON).
// Это свяжет имя поля (Light/Speed/SelectItem/...) с байтовым смещением структуры.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class FindStringXrefs extends GhidraScript {
    // Уникальные ключи настроек подсветки (из Keyboard.json → LightInfo).
    static final String[] KEYS = {
        "SelectItem", "ZZCCLedMode", "OldLedmode", "MultiColor", "Light", "Speed"
    };

    boolean isKey(String s) {
        if (s == null) return false;
        for (String k : KEYS) if (s.equals(k)) return true;
        return false;
    }

    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager rm = currentProgram.getReferenceManager();
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();

        // 1) Находим адреса строк-ключей.
        Set<Address> keyAddrs = new HashSet<Address>();
        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext()) {
            Data d = di.next();
            Object v = d.getValue();
            if (v != null && isKey(v.toString())) {
                println("string \"" + v + "\" @ " + d.getAddress());
                keyAddrs.add(d.getAddress());
            }
        }

        // 2) Функции, ссылающиеся на эти строки.
        Set<Function> funcs = new HashSet<Function>();
        for (Address a : keyAddrs) {
            for (Reference r : rm.getReferencesTo(a)) {
                Function fn = fm.getFunctionContaining(r.getFromAddress());
                if (fn != null) funcs.add(fn);
            }
        }
        println("\nФункций со ссылками на ключи: " + funcs.size());

        // 3) Декомпилируем их (парсер/сериализатор покажет offset каждого поля).
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Function fn : funcs) {
            long size = fn.getBody().getNumAddresses();
            println("\n---- " + fn.getName() + " @ " + fn.getEntryPoint() + " (" + size + " bytes) ----");
            if (size > 4000) { println("(skip large)"); continue; }
            DecompileResults res = decomp.decompileFunction(fn, 90, mon);
            if (res != null && res.decompileCompleted()) println(res.getDecompiledFunction().getC());
            else println("(decompile failed)");
        }
        println("\n==== DONE ====");
    }
}
