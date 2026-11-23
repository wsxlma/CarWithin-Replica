// Dump raw instruction listing for one or more functions (by name substring).
// @category Analysis
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.address.*;

public class ListFunc extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args[0];
        StringBuilder sb = new StringBuilder();
        FunctionManager fm = currentProgram.getFunctionManager();
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName();
            boolean match = args.length <= 1;
            for (int i = 1; i < args.length; i++) {
                if (name.contains(args[i])) { match = true; break; }
            }
            if (!match) continue;
            sb.append("\n===== ").append(name).append(" @ ").append(f.getEntryPoint()).append(" =====\n");
            Listing lst = currentProgram.getListing();
            InstructionIterator it = lst.getInstructions(f.getBody(), true);
            int n = 0;
            while (it.hasNext() && n < 400) {
                Instruction ins = it.next();
                sb.append(ins.getAddress()).append("  ").append(ins.toString()).append("\n");
                n++;
            }
        }
        java.nio.file.Files.write(java.nio.file.Paths.get(outPath),
                sb.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        println("written " + outPath);
    }
}