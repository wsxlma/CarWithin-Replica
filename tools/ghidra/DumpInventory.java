// Ghidra headless script: dump full symbol inventory (functions, classes, methods, strings refs).
// Usage: analyzeHeadless <proj> <name> -process <binary> -scriptPath tools/ghidra \
//        -postScript DumpInventory.java out.txt
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolTable;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class DumpInventory extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args.length > 0 ? args[0] : "inventory.txt";

        try (PrintWriter out = new PrintWriter(new FileWriter(outPath))) {
            out.println("# program: " + currentProgram.getName());
            out.println("# imageBase: " + currentProgram.getImageBase());
            out.println();

            // ---- functions ----
            List<String> fns = new ArrayList<>();
            FunctionManager fm = currentProgram.getFunctionManager();
            for (Function f : fm.getFunctions(true)) {
                fns.add(f.getEntryPoint() + "\t" + f.getName());
            }
            Collections.sort(fns);
            out.println("## FUNCTIONS " + fns.size());
            for (String s : fns) out.println(s);
            out.println();

            // ---- all symbols ----
            List<String> syms = new ArrayList<>();
            SymbolTable st = currentProgram.getSymbolTable();
            SymbolIterator it = st.getAllSymbols(true);
            while (it.hasNext()) {
                Symbol s = it.next();
                syms.add(s.getAddress() + "\t" + s.getSymbolType() + "\t" + s.getName(true));
            }
            Collections.sort(syms);
            out.println("## SYMBOLS " + syms.size());
            for (String s : syms) out.println(s);
            out.println();
        }
        println("inventory written: " + outPath);
    }
}