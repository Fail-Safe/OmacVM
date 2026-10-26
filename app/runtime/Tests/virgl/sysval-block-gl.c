/* GL stand-in for test-sysval-block: a dylib whose __interpose section replaces
 * glGetActiveUniformBlockiv (also where libepoxy looks it up with dlsym), so the test can
 * make the GL's answer for a program's VirglBlock fail (#547):
 *  1 the query fails as on a GL that refuses calls: a GL error, nothing written;
 *  2 the GL reports a block smaller than vrend's sysval block (16 bytes).
 * It also counts the glDrawArrays calls that reach the GL. Test-only; never shipped. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/gl3.h>
#include <string.h>

static int fault;
static unsigned long faults_done, draws;

void sysval_block_fault(int mode)
{
   fault = mode;
}

unsigned long sysval_block_faults(void)
{
   return faults_done;
}

unsigned long sysval_block_draws(void)
{
   return draws;
}

static void stand_in_GetActiveUniformBlockiv(GLuint program, GLuint index, GLenum pname,
                                             GLint *params)
{
   if (fault && pname == GL_UNIFORM_BLOCK_DATA_SIZE) {
      char name[32] = "";
      GLsizei len = 0;
      glGetActiveUniformBlockName(program, index, sizeof(name), &len, name);
      if (!strcmp(name, "VirglBlock")) {
         faults_done++;
         if (fault == 1) {
            /* an index past the program's blocks: GL_INVALID_VALUE, params untouched */
            glGetActiveUniformBlockiv(program, 0x7fffffff, pname, params);
            return;
         }
         *params = 16;
         return;
      }
   }
   glGetActiveUniformBlockiv(program, index, pname, params);
}

static void stand_in_DrawArrays(GLenum mode, GLint first, GLsizei count)
{
   draws++;
   glDrawArrays(mode, first, count);
}

__attribute__((used)) static const struct {
   const void *replacement;
   const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
   { (const void *)stand_in_GetActiveUniformBlockiv, (const void *)glGetActiveUniformBlockiv },
   { (const void *)stand_in_DrawArrays, (const void *)glDrawArrays },
};
