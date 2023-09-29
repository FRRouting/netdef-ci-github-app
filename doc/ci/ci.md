# Introduction

In this document we will describe the CI behaviors and the possible states of each Action we have.

# States

- Queued, in the normal PR flow, this state will not appear to avoid polluting GitHub Checks. It only appears when we execute a ReRun (ci:rerun).
- In Progress, at this point we sent the execution link to GitHub.
- Success, no errors detected by Bamboo CI
- Failure, errors detect by Bamboo CI. In the output, errors will be prioritized after other executions.
- Skipped, Some prerequisite for execution failed or was not met. Example: Problem generating project images.

# State Machine
                          
```                 

                    //================================== ReRun =======================\\     
                    ||  //================ ReRun ===============\\                    ||
                    ||  ||                                      ||                    || 
                    ||  ||                                   +---------+              ||
                    ||  ||                    //===========> | Success | = ReRun =\\  ||
                    ||  ||                    ||             +---------+          ||  ||
                    ||  \/                    ||                                  \/  \/
 +---------+      +--------+      +-------------+                            +-----------+                                
 | Skipped | <=== | Queued | ===> | In progress | ========= ReRun =========> | Cancelled |       
 +---------+      +--------+      +-------------+                            +-----------+
                    /\   /\            ||   ||                                    /\
                    ||   ||            ||   ||             +---------+            || 
                    ||   \\=== ReRun ==//   \\===========> | Failure | == ReRun ==//
                    ||                                     +---------+
                    ||                                        ||
                    \\============= ReRun or Retry ===========//
  
```

