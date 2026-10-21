// Ghidra script (Java): декомпилирует заданные функции и всех, кто их вызывает.
// Цель — найти формирование пакета команды подсветки (mode/brightness/color),
// который отправляется через транспортные функции HID.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.address.Address;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class DumpCallers extends GhidraScript {
    // Транспортные/служебные функции, найденные ранее (entry-адреса).
    static final String[] SEEDS = { "00477500", "00477fe0" };

    DecompInterface decomp;
    ConsoleTaskMonitor mon;
    FunctionManager fm;
    Set<String> printed = new HashSet<String>();

    void dump(Function fn, String tag) {
        if (fn == null) return;
        String key = fn.getEntryPoint().toString();
        if (!printed.add(key)) return;
        println("\n---- " + tag + ": " + fn.getName() + " @ " + key + " ----");
        DecompileResults res = decomp.decompileFunction(fn, 60, mon);
        if (res != null && res.decompileCompleted()) println(res.getDecompiledFunction().getC());
        else println("(decompile failed)");
    }

    @Override
    public void run() throws Exception {
        fm = currentProgram.getFunctionManager();
        mon = new ConsoleTaskMonitor();
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        for (String hex : SEEDS) {
            Address a = currentProgram.getAddressFactory().getAddress(hex);
            Function seed = fm.getFunctionAt(a);
            if (seed == null) { println("seed not found: " + hex); continue; }
            println("\n======== SEED " + seed.getName() + " @ " + hex + " ========");
            // callers первого уровня — там, вероятно, строится пакет команды.
            for (Function c : seed.getCallingFunctions(mon)) dump(c, "caller");
        }
        println("\n==== DONE ====");
    }
}
