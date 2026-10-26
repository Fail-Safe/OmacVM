/* GL stand-in for test-sysval-block: a dylib whose __interpose section replaces
 * glGetActiveUniformBlockiv (also where libepoxy looks it up with dlsym), so the test can
 * make the GL's answer for a program's VirglBlock fail (#547):
 *  1 the query fails as on a GL that refuses calls: a GL error, nothing written;
 *  2 the GL reports a block smaller than vrend's sysval block (16 bytes).
 * gl_pervertex_redeclare(1): a vertex shader that writes gl_Position without redeclaring
 * gl_PerVertex gets the redeclaration. Apple's GL refuses to link such a separable shader
 * (GLSL 4.10; Mesa's GL does not insist) and vrend's last vertex stage never redeclares
 * it, so without this no separable pipeline links on the Mac at all.
 * It also counts the glDrawArrays calls that reach the GL and every VirglBlock size
 * query. Test-only; never shipped. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/gl3.h>
#include <stdlib.h>
#include <string.h>

static int fault, pervertex;
static unsigned long faults_done, draws, block_queries;

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

unsigned long sysval_block_queries(void)
{
   return block_queries;
}

void gl_pervertex_redeclare(int on)
{
   pervertex = on;
}


static void stand_in_GetActiveUniformBlockiv(GLuint program, GLuint index, GLenum pname,
                                             GLint *params)
{
   if (fault && pname == GL_UNIFORM_BLOCK_DATA_SIZE) {
      char name[32] = "";
      GLsizei len = 0;
      glGetActiveUniformBlockName(program, index, sizeof(name), &len, name);
      if (!strcmp(name, "VirglBlock")) {
         block_queries++;
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
   if (pname == GL_UNIFORM_BLOCK_DATA_SIZE) {
      char name[32] = "";
      GLsizei len = 0;
      glGetActiveUniformBlockName(program, index, sizeof(name), &len, name);
      block_queries += !strcmp(name, "VirglBlock");
   }
   glGetActiveUniformBlockiv(program, index, pname, params);
}


static void stand_in_ShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings,
                                  const GLint *lengths)
{
   static const char decl[] = "out gl_PerVertex { vec4 gl_Position; };\n";
   size_t total = 0;
   for (GLsizei i = 0; pervertex && i < count; i++)
      total += lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
   char *all = pervertex ? malloc(total + sizeof(decl)) : NULL;
   if (!all) {
      glShaderSource(shader, count, strings, lengths);
      return;
   }
   size_t n = 0;
   for (GLsizei i = 0; i < count; i++) {
      size_t len = lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
      memcpy(all + n, strings[i], len);
      n += len;
   }
   all[n] = 0;
   if (strstr(all, "gl_Position") && !strstr(all, "gl_PerVertex")) {
      /* before the first line that is not a preprocessor line */
      char *at = all;
      while (*at == '#' || *at == '\n') {
         char *eol = strchr(at, '\n');
         if (!eol)
            break;
         at = eol + 1;
      }
      memmove(at + sizeof(decl) - 1, at, strlen(at) + 1);
      memcpy(at, decl, sizeof(decl) - 1);
   }
   const GLchar *one = all;
   glShaderSource(shader, 1, &one, NULL);
   free(all);
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
   { (const void *)stand_in_ShaderSource, (const void *)glShaderSource },
};
