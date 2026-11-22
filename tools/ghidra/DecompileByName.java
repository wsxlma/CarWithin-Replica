// Ghidra headless script: decompile functions whose (mangled) name contains any filter.
// Usage:
//   analyzeHeadless <proj> <name> -import <binary> -scriptPath tools/ghidra \
//       -postScript DecompileByName.java out.txt aboutLinks SettingsRow
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;

import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompileByName extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args.length > 0 ? args[0] : "decompiled.txt";

        DecompInterface ifc = new DecompInterface();
        ifc.toggleCCode(true);
        ifc.toggleSyntaxTree(true);
        ifc.setSimplificationStyle("decompile");
        if (!ifc.openProgram(currentProgram)) {
            println("openProgram failed: " + ifc.getLastMessage());
            return;
        }

        FunctionManager fm = currentProgram.getFunctionManager();
        int total = 0;
        int matched = 0;

        try (PrintWriter out = new PrintWriter(new FileWriter(outPath))) {
            out.println("# program: " + currentProgram.getName());
            out.println("# imageBase: " + currentProgram.getImageBase());
            out.println();

            for (Function f : fm.getFunctions(true)) {
                total++;
                String name = f.getName();
                boolean match = args.length <= 1;
                for (int i = 1; i < args.length && !match; i++) {
                    if (name.contains(args[i])) {
                        match = true;
                    }
                }
                if (!match) {
                    continue;
                }
                matched++;
                out.println("===== " + name + " @ " + f.getEntryPoint() + " =====");
                DecompileResults res = ifc.decompileFunction(f, 90, monitor);
                if (res != null && res.decompileCompleted() && res.getDecompiledFunction() != null) {
                    out.println(res.getDecompiledFunction().getC());
                } else {
                    out.println("// decompile failed: "
                        + (res == null ? "null result" : res.getErrorMessage()));
                }
                out.println();
                out.flush();
            }
        } finally {
            ifc.dispose();
        }

        println("functions=" + total + " matched=" + matched + " output=" + outPath);
    }
}
