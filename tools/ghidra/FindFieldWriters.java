// Ghidra script (Java): находит функции, обращающиеся к полям структуры
// настроек подсветки (offset 0x21C8..0x21DC в объекте устройства), и
// декомпилирует их. Цель — восстановить раскладку байтов блока (mode/RGB/яркость).
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class FindFieldWriters extends GhidraScript {
    // Диапазон смещений структуры настроек подсветки.
    static final long LO = 0x21C8, HI = 0x21DC;

    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();

        // 1) Собираем функции, в инструкциях которых есть скаляр из диапазона смещений.
        Set<Function> hits = new HashSet<Function>();
        InstructionIterator it = currentProgram.getListing().getInstructions(true);
        while (it.hasNext()) {
            Instruction ins = it.next();
            for (int op = 0; op < ins.getNumOperands(); op++) {
                for (Object o : ins.getOpObjects(op)) {
                    if (o instanceof Scalar) {
                        long v = ((Scalar) o).getUnsignedValue();
                        if (v >= LO && v <= HI) {
                            Function fn = fm.getFunctionContaining(ins.getAddress());
                            if (fn != null) hits.add(fn);
                        }
                    }
                }
            }
        }
        println("Функций, обращающихся к 0x21C8..0x21DC: " + hits.size());

        // 2) Декомпилируем найденные (но не гигантские) функции.
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Function fn : hits) {
            long size = fn.getBody().getNumAddresses();
            if (size > 1200) { // пропускаем очень большие (UI-диспетчеры)
                println("\n---- SKIP large: " + fn.getName() + " @ " + fn.getEntryPoint() + " (" + size + " bytes) ----");
                continue;
            }
            println("\n---- " + fn.getName() + " @ " + fn.getEntryPoint() + " ----");
            DecompileResults res = decomp.decompileFunction(fn, 60, mon);
            if (res != null && res.decompileCompleted()) println(res.getDecompiledFunction().getC());
            else println("(decompile failed)");
        }
        println("\n==== DONE ====");
    }
}
